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

package = "apisix"
version = "master-0"
supported_platforms = {"linux"}

source = {
    url = "git://github.com/apache/apisix",
    branch = "master",
}

description = {
    summary = "Apache APISIX is a cloud-native microservices API gateway, delivering the ultimate performance, security, open source and scalable platform for all your APIs and microservices.",
    homepage = "https://github.com/apache/apisix",
    license = "Apache License 2.0",
}

dependencies = {
    "lua-resty-ctxdump = 0.1-0",
    "lyaml = 6.2.8",
    "api7-lua-resty-dns-client = 7.0.1",
    "lua-resty-template = 2.0",
    "lua-resty-etcd = 1.10.5",
    "api7-lua-resty-http = 0.2.2-0",
    "lua-resty-balancer = 0.04",
    "lua-resty-ngxvar = 0.5.2",
    "lua-resty-jit-uuid = 0.0.7",
    "lua-resty-worker-events = 1.0.0",
    "lua-resty-healthcheck-api7 = 3.2.0",
    "api7-lua-resty-jwt = 0.2.5",
    "lua-resty-hmac-ffi = 0.06-1",
    "lua-resty-cookie = 0.2.0-1",
    "lua-resty-session = 3.10",
    "opentracing-openresty = 0.1",
    "lua-resty-radixtree = 2.9.2",
    "lua-protobuf = 0.5.2-1",
    "lua-resty-openidc = 1.7.6-3",
    "luafilesystem = 1.7.0-2",
    "nginx-lua-prometheus-api7 = 0.20240201-1",
    "jsonschema = 0.9.8",
    "lua-resty-ipmatcher = 0.6.1",
    "lua-resty-kafka = 0.23-0",
    "lua-resty-logger-socket = 2.0.1-0",
    "skywalking-nginx-lua = 1.0.1",
    "base64 = 1.5-2",
    "binaryheap = 0.4",
    "api7-dkjson = 0.1.1",
    "resty-redis-cluster = 1.05-1",
    "lua-resty-expr = 1.3.2",
    "graphql = 0.0.2",
    "argparse = 0.7.1-1",
    "luasocket = 3.1.0-1",
    "luasec = 1.3.2-1",
    "lua-resty-consul = 0.3-2",
    "penlight = 1.13.1",
    "ext-plugin-proto = 0.6.1",
    "casbin = 1.41.9-1",
    "inspect == 3.1.1",
    "lua-resty-rocketmq = 0.3.0-0",
    "opentelemetry-lua = 0.2-3",
    "net-url = 0.9-1",
    "xml2lua = 1.5-2",
    "nanoid = 0.1-1",
    "lua-resty-mediador = 0.1.2-1",
    "lua-resty-ldap = 0.1.0-0",
    "lua-resty-t1k = 1.1.5",
    "brotli-ffi = 0.3-1",
    "lua-ffi-zlib = 0.6-0",
    "jsonpath = 1.0-1",
    "api7-lua-resty-aws == 2.0.2-1",
    "multipart = 0.5.9-1",
}

build = {
    type = "make",
    build_variables = {
        CFLAGS="$(CFLAGS)",
        LIBFLAG="$(LIBFLAG)",
        LUA_LIBDIR="$(LUA_LIBDIR)",
        LUA_BINDIR="$(LUA_BINDIR)",
        LUA_INCDIR="$(LUA_INCDIR)",
        LUA="$(LUA)",
        OPENSSL_INCDIR="$(OPENSSL_INCDIR)",
        OPENSSL_LIBDIR="$(OPENSSL_LIBDIR)",
    },
    install_variables = {
        ENV_INST_PREFIX="$(PREFIX)",
        ENV_INST_BINDIR="$(BINDIR)",
        ENV_INST_LIBDIR="$(LIBDIR)",
        ENV_INST_LUADIR="$(LUADIR)",
        ENV_INST_CONFDIR="$(CONFDIR)",
    },
}
