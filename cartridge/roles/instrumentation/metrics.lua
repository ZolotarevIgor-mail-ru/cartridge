local cartridge = require("cartridge")
local argparse = require("cartridge.argparse")
local metrics = require("metrics")

local handlers = {
  ['json'] = function(req)
      local json_exporter = require("metrics.plugins.json")
      return req:render({ text = json_exporter.export() })
  end,
  ['prometheus'] = function(...)
      local http_handler = require("metrics.plugins.prometheus").collect_http
      return http_handler(...)
  end,
}

local collectors = {
  ['default'] = function(...)
      metrics.enable_default_metrics()
  end
}

local path_format = {}

local function init()
    local params, err = argparse.parse()
    if err ~= nil then
        return err
    end
end

local function validate_config(conf_new, conf_old)
    --[[
    metrics:
      export:
        - path: "/metrics/json"
          format: "json"
        - path: "/metrics/prom"
          format: "prometheus"
      collect:
        default:
    ]]

    return true
end

local function apply_config(conf)
    local metrics_conf = conf.metrics
    if metrics_conf == nil then
        return true
    end

    for name, opts in pairs(metrics_conf.collect) do
        collectors[name](opts)
    end

    local params = argparse.parse()
    metrics.set_global_labels({alias = params.alias})

    local httpd = cartridge.service_get("httpd")
    for _, exporter in ipairs(metrics_conf.export) do
        local path, format = exporter.path, exporter.format
        if path_format[path] ~= format then
            if path_format[path] then
                httpd.routes[httpd.iroutes[path]] = nil
                httpd.iroutes[path] = nil
            end
            httpd:route({method = "GET", name = path, path = path}, handlers[format])
            path_format[path] = format
        end
    end
    for path, _ in pairs(path_format) do
        local is_present = false
        for _, exporter in ipairs(metrics_conf.export) do
            if path == exporter.path then
                is_present = true
                break
            end
        end
        if not is_present then
            httpd.routes[httpd.iroutes[path]] = nil
            httpd.iroutes[path] = nil
            path_format[path] = nil
        end
    end
end

return setmetatable({
    role_name = 'metrics',

    init = init,
    validate_config = validate_config,
    apply_config = apply_config
}, {__index = metrics})
