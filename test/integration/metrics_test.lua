local fio = require('fio')
local t = require('luatest')
local g = t.group()
local json = require("json")

local helpers = require('test.helper')

g.before_all = function()
    g.cluster = helpers.Cluster:new({
        datadir = fio.tempdir(),
        server_command = helpers.entrypoint('srv_basic'),
        cookie = require('digest').urandom(6):hex(),
        replicasets = {
            {
                uuid = helpers.uuid('a'),
                roles = {
                  'metrics-configurator'
                },
                servers = {
                    {
                        alias = 'main',
                        http_port = 8081,
                        advertise_port = 13301,
                        instance_uuid = helpers.uuid('a', 'a', 1)
                    }
                },
            },
        },
    })
    g.cluster:start()
end

g.after_all = function()
    g.cluster:stop()
    fio.rmtree(g.cluster.datadir)
end

g.test_role_enabled = function()
    local resp = g.cluster.main_server.net_box:eval([[
      local cartridge = require("cartridge")
      return cartridge.service_get("metrics-configurator") == nil
    ]])
    t.assert_equals(resp, false)
end

g.test_role_add_metrics_http_endpoint = function()
    local server = g.cluster.main_server
    local resp = server:http_request('put', '/admin/config', {
        body = json.encode({
          metrics = {
            export = {
              {
                path = "/metrics",
                format = "json"
              }
            },
            collect = {
              default = {},
            }
          }
        }),
        raise = false
    })

    local resp = g.cluster.main_server.net_box:eval([[
      local cartridge = require("cartridge")
      local metrics = cartridge.service_get("metrics")
      metrics.counter('test-counter'):inc(1)
    ]])

    local counter_present = false

    local resp = server:http_request('get', '/metrics')
    t.assert_equals(resp.status, 200)
    for _, obs in pairs(resp.json) do
      t.assert_equals(
          g.cluster.main_server.alias, obs.label_pairs["alias"],
          ("Alias label is present in metric %s"):format(obs.metric_name)
      )
      if obs.metric_name == 'test-counter' then
          counter_present = true
          t.assert_equals(obs.value, 1)
      end
    end
    t.assert_equals(counter_present, true)
end
