--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local base_prometheus = require("prometheus")
local core      = require("apisix.core")
local plugin    = require("apisix.plugin")
local control   = require("apisix.control.v1")
local ipairs    = ipairs
local pairs     = pairs
local ngx       = ngx
local re_gmatch = ngx.re.gmatch
local ffi       = require("ffi")
local C         = ffi.C
local pcall = pcall
local select = select
local type = type
local prometheus
local prometheus_bkp
local router = require("apisix.router")
local get_routes = router.http_routes
local get_ssls   = router.ssls
local get_services = require("apisix.http.service").services
local get_consumers = require("apisix.consumer").consumers
local get_upstreams = require("apisix.upstream").upstreams
local get_global_rules = require("apisix.global_rules").global_rules
local get_global_rules_prev_index = require("apisix.global_rules").get_pre_index
local clear_tab = core.table.clear
local get_stream_routes = router.stream_routes
local get_protos = require("apisix.plugins.grpc-transcode.proto").protos
local service_fetch = require("apisix.http.service").get
local latency_details = require("apisix.utils.log-util").latency_details_in_ms
local xrpc = require("apisix.stream.xrpc")
local unpack = unpack
local next = next


local ngx_capture
if ngx.config.subsystem == "http" then
    ngx_capture = ngx.location.capture
end


local plugin_name = "prometheus"
local default_export_uri = "/apisix/prometheus/metrics"
-- Default set of latency buckets, 1ms to 60s:
local DEFAULT_BUCKETS = {1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000}

local metrics = {}

local inner_tab_arr = {}

local function gen_arr(...)
    clear_tab(inner_tab_arr)
    for i = 1, select('#', ...) do
        inner_tab_arr[i] = select(i, ...)
    end

    return inner_tab_arr
end

local extra_labels_tbl = {}

local function extra_labels(name, ctx)
    clear_tab(extra_labels_tbl)

    local attr = plugin.plugin_attr("prometheus")
    local metrics = attr.metrics

    if metrics and metrics[name] and metrics[name].extra_labels then
        local labels = metrics[name].extra_labels
        for _, kv in ipairs(labels) do
            local val, v = next(kv)
            if ctx then
                val = ctx.var[v:sub(2)]
                if val == nil then
                    val = ""
                end
            end
            core.table.insert(extra_labels_tbl, val)
        end
    end

    return extra_labels_tbl
end


local _M = {}


local function init_stream_metrics()
    metrics.stream_connection_total = prometheus:counter("stream_connection_total",
        "Total number of connections handled per stream route in APISIX",
        {"route"})

    xrpc.init_metrics(prometheus)
end


function _M.http_init(prometheus_enabled_in_stream)
    -- todo: support hot reload, we may need to update the lua-prometheus
    -- library
    if ngx.get_phase() ~= "init" and ngx.get_phase() ~= "init_worker"  then
        if prometheus_bkp then
            prometheus = prometheus_bkp
        end
        return
    end

    clear_tab(metrics)

    -- Newly added metrics should follow the naming best practices described in
    -- https://prometheus.io/docs/practices/naming/#metric-names
    -- For example,
    -- 1. Add unit as the suffix
    -- 2. Add `_total` as the suffix if the metric type is counter
    -- 3. Use base unit
    -- We keep the old metric names for the compatibility.

    -- across all services
    local metric_prefix = "apisix_"
    local attr = plugin.plugin_attr("prometheus")
    if attr and attr.metric_prefix then
        metric_prefix = attr.metric_prefix
    end

    local status_metrics_exptime = core.table.try_read_attr(attr, "metrics",
                                   "http_status", "expire")
    local latency_metrics_exptime = core.table.try_read_attr(attr, "metrics",
                                   "http_latency", "expire")
    local bandwidth_metrics_exptime = core.table.try_read_attr(attr, "metrics",
                                   "bandwidth", "expire")
    local upstream_status_exptime = core.table.try_read_attr(attr, "metrics",
                                   "upstream_status", "expire")

    prometheus = base_prometheus.init("prometheus-metrics", metric_prefix)

    metrics.connections = prometheus:gauge("nginx_http_current_connections",
            "Number of HTTP connections",
            {"state"})

    metrics.requests = prometheus:gauge("http_requests_total",
            "The total number of client requests since APISIX started")

    metrics.etcd_reachable = prometheus:gauge("etcd_reachable",
            "Config server etcd reachable from APISIX, 0 is unreachable")

    metrics.node_info = prometheus:gauge("node_info",
            "Info of APISIX node",
            {"hostname", "version"})

    metrics.etcd_modify_indexes = prometheus:gauge("etcd_modify_indexes",
            "Etcd modify index for APISIX keys",
            {"key"})

    metrics.shared_dict_capacity_bytes = prometheus:gauge("shared_dict_capacity_bytes",
            "The capacity of each nginx shared DICT since APISIX start",
            {"name"})

    metrics.shared_dict_free_space_bytes = prometheus:gauge("shared_dict_free_space_bytes",
            "The free space of each nginx shared DICT since APISIX start",
            {"name"})

    metrics.upstream_status = prometheus:gauge("upstream_status",
            "Upstream status from health check",
            {"name", "ip", "port"},
            upstream_status_exptime)

    -- per service

    -- The consumer label indicates the name of consumer corresponds to the
    -- request to the route/service, it will be an empty string if there is
    -- no consumer in request.
    metrics.status = prometheus:counter("http_status",
            "HTTP status codes per service in APISIX",
            {"code", "route", "matched_uri", "matched_host", "service", "consumer", "node",
            unpack(extra_labels("http_status"))},
            status_metrics_exptime)

    local buckets = DEFAULT_BUCKETS
    if attr and attr.default_buckets then
        buckets = attr.default_buckets
    end

    metrics.latency = prometheus:histogram("http_latency",
        "HTTP request latency in milliseconds per service in APISIX",
        {"type", "route", "service", "consumer", "node", unpack(extra_labels("http_latency"))},
        buckets, latency_metrics_exptime)

    metrics.bandwidth = prometheus:counter("bandwidth",
            "Total bandwidth in bytes consumed per service in APISIX",
            {"type", "route", "service", "consumer", "node", unpack(extra_labels("bandwidth"))},
            bandwidth_metrics_exptime)

    if prometheus_enabled_in_stream then
        init_stream_metrics()
    end
end


function _M.stream_init()
    if ngx.get_phase() ~= "init" and ngx.get_phase() ~= "init_worker"  then
        return
    end

    if not pcall(function() return C.ngx_meta_lua_ffi_shdict_udata_to_zone end) then
        core.log.error("need to build APISIX-Runtime to support L4 metrics")
        return
    end

    clear_tab(metrics)

    local metric_prefix = "apisix_"
    local attr = plugin.plugin_attr("prometheus")
    if attr and attr.metric_prefix then
        metric_prefix = attr.metric_prefix
    end

    prometheus = base_prometheus.init("prometheus-metrics", metric_prefix)

    init_stream_metrics()
end


function _M.http_log(conf, ctx)
    local vars = ctx.var

    local route_id = ""
    local balancer_ip = ctx.balancer_ip or ""
    local service_id = ""
    local consumer_name = ctx.consumer_name or ""

    local matched_route = ctx.matched_route and ctx.matched_route.value
    if matched_route then
        route_id = matched_route.id
        service_id = matched_route.service_id or ""
        if conf.prefer_name == true then
            route_id = matched_route.name or route_id
            if service_id ~= "" then
                local service = service_fetch(service_id)
                service_id = service and service.value.name or service_id
            end
        end
    end

    local matched_uri = ""
    local matched_host = ""
    if ctx.curr_req_matched then
        matched_uri = ctx.curr_req_matched._path or ""
        matched_host = ctx.curr_req_matched._host or ""
    end

    metrics.status:inc(1,
        gen_arr(vars.status, route_id, matched_uri, matched_host,
                service_id, consumer_name, balancer_ip,
                unpack(extra_labels("http_status", ctx))))

    local latency, upstream_latency, apisix_latency = latency_details(ctx)
    local latency_extra_label_values = extra_labels("http_latency", ctx)

    metrics.latency:observe(latency,
        gen_arr("request", route_id, service_id, consumer_name, balancer_ip,
        unpack(latency_extra_label_values)))

    if upstream_latency then
        metrics.latency:observe(upstream_latency,
            gen_arr("upstream", route_id, service_id, consumer_name, balancer_ip,
            unpack(latency_extra_label_values)))
    end

    metrics.latency:observe(apisix_latency,
        gen_arr("apisix", route_id, service_id, consumer_name, balancer_ip,
        unpack(latency_extra_label_values)))

    local bandwidth_extra_label_values = extra_labels("bandwidth", ctx)

    metrics.bandwidth:inc(vars.request_length,
        gen_arr("ingress", route_id, service_id, consumer_name, balancer_ip,
        unpack(bandwidth_extra_label_values)))

    metrics.bandwidth:inc(vars.bytes_sent,
        gen_arr("egress", route_id, service_id, consumer_name, balancer_ip,
        unpack(bandwidth_extra_label_values)))
end


function _M.stream_log(conf, ctx)
    local route_id = ""
    local matched_route = ctx.matched_route and ctx.matched_route.value
    if matched_route then
        route_id = matched_route.id
        if conf.prefer_name == true then
            route_id = matched_route.name or route_id
        end
    end

    metrics.stream_connection_total:inc(1, gen_arr(route_id))
end


local ngx_status_items = {"active", "accepted", "handled", "total",
                         "reading", "writing", "waiting"}
local label_values = {}

local function nginx_status()
    local res = ngx_capture("/apisix/nginx_status")
    if not res or res.status ~= 200 then
        core.log.error("failed to fetch Nginx status")
        return
    end

    -- Active connections: 2
    -- server accepts handled requests
    --   26 26 84
    -- Reading: 0 Writing: 1 Waiting: 1

    local iterator, err = re_gmatch(res.body, [[(\d+)]], "jmo")
    if not iterator then
        core.log.error("failed to re.gmatch Nginx status: ", err)
        return
    end

    for _, name in ipairs(ngx_status_items) do
        local val = iterator()
        if not val then
            break
        end

        if name == "total" then
            metrics.requests:set(val[0])
        else
            label_values[1] = name
            metrics.connections:set(val[0], label_values)
        end
    end
end


local key_values = {}
local function set_modify_index(key, items, items_ver, global_max_index)
    clear_tab(key_values)
    local max_idx = 0
    if items_ver and items then
        for _, item in ipairs(items) do
            if type(item) == "table" then
                local modify_index = item.orig_modifiedIndex or item.modifiedIndex
                if modify_index > max_idx then
                    max_idx = modify_index
                end
            end
        end
    end

    key_values[1] = key
    metrics.etcd_modify_indexes:set(max_idx, key_values)


    global_max_index = max_idx > global_max_index and max_idx or global_max_index

    return global_max_index
end


local function etcd_modify_index()
    clear_tab(key_values)
    local global_max_idx = 0

    -- routes
    local routes, routes_ver = get_routes()
    global_max_idx = set_modify_index("routes", routes, routes_ver, global_max_idx)

    -- services
    local services, services_ver = get_services()
    global_max_idx = set_modify_index("services", services, services_ver, global_max_idx)

    -- ssls
    local ssls, ssls_ver = get_ssls()
    global_max_idx = set_modify_index("ssls", ssls, ssls_ver, global_max_idx)

    -- consumers
    local consumers, consumers_ver = get_consumers()
    global_max_idx = set_modify_index("consumers", consumers, consumers_ver, global_max_idx)

    -- global_rules
    local global_rules, global_rules_ver = get_global_rules()
    if global_rules then
        global_max_idx = set_modify_index("global_rules", global_rules,
            global_rules_ver, global_max_idx)

        -- prev_index
        key_values[1] = "prev_index"
        local prev_index = get_global_rules_prev_index()
        metrics.etcd_modify_indexes:set(prev_index, key_values)

    else
        global_max_idx = set_modify_index("global_rules", nil, nil, global_max_idx)
    end

    -- upstreams
    local upstreams, upstreams_ver = get_upstreams()
    global_max_idx = set_modify_index("upstreams", upstreams, upstreams_ver, global_max_idx)

    -- stream_routes
    local stream_routes, stream_routes_ver = get_stream_routes()
    global_max_idx = set_modify_index("stream_routes", stream_routes,
        stream_routes_ver, global_max_idx)

    -- proto
    local protos, protos_ver = get_protos()
    global_max_idx = set_modify_index("protos", protos, protos_ver, global_max_idx)

    -- global max
    key_values[1] = "max_modify_index"
    metrics.etcd_modify_indexes:set(global_max_idx, key_values)

end


local function shared_dict_status()
    local name = {}
    for shared_dict_name, shared_dict in pairs(ngx.shared) do
        name[1] = shared_dict_name
        metrics.shared_dict_capacity_bytes:set(shared_dict:capacity(), name)
        metrics.shared_dict_free_space_bytes:set(shared_dict:free_space(), name)
    end
end


local function collect(ctx, stream_only)
    if not prometheus or not metrics then
        core.log.error("prometheus: plugin is not initialized, please make sure ",
                     " 'prometheus_metrics' shared dict is present in nginx template")
        return 500, {message = "An unexpected error occurred"}
    end

    -- collect ngx.shared.DICT status
    shared_dict_status()

    -- across all services
    nginx_status()

    local config = core.config.new()

    -- config server status
    local vars = ngx.var or {}
    local hostname = vars.hostname or ""
    local version = core.version.VERSION or ""

    -- we can't get etcd index in metric server if only stream subsystem is enabled
    if config.type == "etcd" and not stream_only then
        -- etcd modify index
        etcd_modify_index()

        local version, err = config:server_version()
        if version then
            metrics.etcd_reachable:set(1)

        else
            metrics.etcd_reachable:set(0)
            core.log.error("prometheus: failed to reach config server while ",
                           "processing metrics endpoint: ", err)
        end

        -- Because request any key from etcd will return the "X-Etcd-Index".
        -- A non-existed key is preferred because it doesn't return too much data.
        -- So use phantom key to get etcd index.
        local res, _ = config:getkey("/phantomkey")
        if res and res.headers then
            clear_tab(key_values)
            -- global max
            key_values[1] = "x_etcd_index"
            metrics.etcd_modify_indexes:set(res.headers["X-Etcd-Index"], key_values)
        end
    end

    metrics.node_info:set(1, gen_arr(hostname, version))

    -- update upstream_status metrics
    local stats = control.get_health_checkers()
    for _, stat in ipairs(stats) do
        for _, node in ipairs(stat.nodes) do
            metrics.upstream_status:set(
                    (node.status == "healthy" or node.status == "mostly_healthy") and 1 or 0,
                    gen_arr(stat.name, node.ip, node.port)
            )
        end
    end

    core.response.set_header("content_type", "text/plain")
    return 200, core.table.concat(prometheus:metric_data())
end
_M.collect = collect


local function get_api(called_by_api_router)
    local export_uri = default_export_uri
    local attr = plugin.plugin_attr(plugin_name)
    if attr and attr.export_uri then
        export_uri = attr.export_uri
    end

    local api = {
        methods = {"GET"},
        uri = export_uri,
        handler = collect
    }

    if not called_by_api_router then
        return api
    end

    if attr.enable_export_server then
        return {}
    end

    return {api}
end
_M.get_api = get_api


function _M.export_metrics(stream_only)
    if not prometheus then
        core.response.exit(200, "{}")
    end
    local api = get_api(false)
    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    if uri == api.uri and method == api.methods[1] then
        local code, body = api.handler(nil, stream_only)
        if code or body then
            core.response.exit(code, body)
        end
    end

    return core.response.exit(404)
end


function _M.metric_data()
    return prometheus:metric_data()
end

function _M.get_prometheus()
    return prometheus
end


function _M.destroy()
    if prometheus ~= nil then
        prometheus_bkp = core.table.deepcopy(prometheus)
        prometheus = nil
    end
end


return _M
