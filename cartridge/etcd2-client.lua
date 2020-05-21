-- TODO
-- etcd2_client implementation
-- lock_delay location
-- connection status
-- set_leaders duplicates

local json = require('json')
local uuid = require('uuid')
local httpc = require('http.client').new({max_connections = 5})
local etcd2 = require('cartridge.etcd2')
local fiber = require('fiber')
local checks = require('checks')
local errors = require('errors')
local digest = require('digest')
local uri_lib = require('uri')

local ClientError  = errors.new_class('ClientError')
local SessionError = errors.new_class('SessionError')
local HttpError = errors.new_class('HttpError')
local EtcdError = errors.new_class('EtcdError')

local function acquire_lock(session, lock_args)
    checks('etcd2_session', {
        uuid = 'string',
        uri = 'string',
    })

    if not session:is_alive() then
        return nil, SessionError:new('Session is dead')
    end

    local request_args = {
        value = json.encode(lock_args),
        ttl = session.lock_delay,
    }

    if session:is_locked() then
        assert(session.lock_index > 0)
        request_args.prevIndex = session.lock_index
    else
        request_args.prevExist = false
    end

    local lock_resp, err = session.connection:request('PUT', '/lock',
        request_args
    )
    if lock_resp == nil then
        if err.etcd_code == etcd2.EcodeNodeExist then
            return false
        else
            session.connection:close()
            return nil, err
        end
    end

    local leaders_resp, err = session.connection:request('GET', '/leaders')
    if leaders_resp == nil then
        if err.etcd_code == etcd2.EcodeKeyNotFound then
            request_args = {
                value = json.encode{}
            }
        else
            return nil, err
        end
    else
        request_args = {
            value = leaders_resp.node.value
        }
    end

    leaders_resp, err = session.connection:request('PUT', '/leaders',
        request_args
    )
    if leaders_resp == nil then
        return nil, err
    end

    session.lock_index = lock_resp.node.modifiedIndex
    session.leaders = json.decode(leaders_resp.node.value)
    session.leaders_index = leaders_resp.node.modifiedIndex
    return true
end

local function get_lock_delay(session)
    checks('etcd2_session')
    return session.lock_delay
end

local function set_leaders(session, updates)
    checks('etcd2_session', 'table')

    if not session:is_alive() then
        return nil, SessionError:new('Session is dropped')
    end

    if not session:is_locked() then
        return nil, SessionError:new('You are not holding the lock')
    end

    assert(session.leaders ~= nil)
    assert(session.leaders_index ~= nil)

    local old_leaders = session.leaders
    local new_leaders = {}
    for _, leader in ipairs(updates) do
        local replicaset_uuid, instance_uuid = unpack(leader)
        if new_leaders[replicaset_uuid] ~= nil then
            return nil, SessionError:new('Duplicate key in updates')
        end

        new_leaders[replicaset_uuid] = instance_uuid
    end

    for replicaset_uuid, instance_uuid in pairs(old_leaders) do
        if new_leaders[replicaset_uuid] == nil then
            new_leaders[replicaset_uuid] = instance_uuid
        end
    end

    if session._set_leaders_mutex == nil then
        session._set_leaders_mutex = fiber.channel(1)
    end
    session._set_leaders_mutex:put(box.NULL)

    local resp, err = SessionError:pcall(function()
        return session.connection:request('PUT', '/leaders', {
            value = json.encode(new_leaders),
            prevIndex = session.leaders_index,
        })
    end)

    session._set_leaders_mutex:get()

    if resp == nil then
        return nil, err
    end

    session.leaders = new_leaders
    session.leaders_index = resp.node.modifiedIndex

    return true
end

local function get_leaders(session)
    checks('etcd2_session')

    if session:is_locked() then
        return session.leaders
    elseif not session:is_alive() then
        return nil, SessionError:new('Session is dropped')
    end

    local resp, err = session.connection:request('GET', '/leaders')
    if resp ~= nil then
        return json.decode(resp.node.value)
    elseif err.etcd_code == etcd2.EcodeKeyNotFound then
        return {}
    else
        return nil, err
    end
end

local function get_coordinator(session)
    checks('etcd2_session')

    if not session:is_alive() then
        return nil
    end

    local resp, err = session.connection:request('GET', '/lock')

    if resp ~= nil then
        return json.decode(resp.node.value)
    elseif err.etcd_code == etcd2.EcodeKeyNotFound then
        -- there is no coordinator
        return nil
    else
        return nil, err
    end
end

local function is_locked(session)
    checks('etcd2_session')
    return session.connection:is_connected()
        and session.lock_index ~= nil
end

local function is_alive(session)
    checks('etcd2_session')
    return session.connection.state ~= 'closed'
end

local function drop(session)
    checks('etcd2_session')
    assert(session.connection ~= nil)

    local lock_index = session.lock_index
    if lock_index ~= nil then
        pcall(function()
            session.lock_index = nil
            session.connection:request('DELETE', '/lock', {
                prevIndex = lock_index,
            })
        end)
    end
    session.connection:close()
    return true
end

local session_mt = {
    __type = 'etcd2_session',
    __index = {
        is_alive = is_alive,
        is_locked = is_locked,
        acquire_lock = acquire_lock,
        set_leaders = set_leaders,
        get_leaders = get_leaders,
        get_lock_delay = get_lock_delay,
        get_coordinator = get_coordinator,
        drop = drop,
    },
}

local function get_session(client)
    checks('etcd2_client')

    if client.session ~= nil
    and client.session:is_alive() then
        return client.session
    end

    local connection = etcd2.connect(client.cfg.endpoints, {
        prefix = client.cfg.prefix,
        request_timeout = client.cfg.request_timeout,
        username = client.cfg.username,
        password = client.cfg.password,
    })

    local session = {
        connection = connection,
        lock_delay = client.cfg.lock_delay,

        lock_index = nil, -- used by session:acquire_lock() and :drop()
        longpoll_index = nil, -- used by client:longpoll()
    }
    client.session = setmetatable(session, session_mt)
    return client.session
end

local function drop_session(client)
    checks('etcd2_client')
    if client.session ~= nil then
        client.session:drop()
        client.session = nil
    end
end

local function longpoll(client, timeout)
    checks('etcd2_client', 'number')

    local deadline = fiber.time() + timeout

    while true do
        local session = client:get_session()
        local timeout = deadline - fiber.time()

        local resp, err
        if session.longpoll_index == nil then
            resp, err = session.connection:request('GET', '/leaders')
            if resp == nil and err.etcd_code == 100 then
                -- key not found
                session.longpoll_index = err.etcd_index
            end
        else
            resp, err = session.connection:request('GET', '/leaders', {
                wait = true,
                waitIndex = session.longpoll_index + 1,
            }, {timeout = timeout})
        end

        if resp ~= nil then
            local new_leaders = json.decode(resp.node.value)
            local old_leaders = session.leaders or {}

            local updates = {}
            if session.longpoll_index == nil then
                updates = new_leaders
            else
                for replicaset_uuid, instance_uuid in pairs(new_leaders) do
                    if old_leaders[replicaset_uuid] ~= new_leaders[replicaset_uuid] then
                        updates[replicaset_uuid] = new_leaders[replicaset_uuid]
                    end
                end
            end

            session.leaders = new_leaders
            session.longpoll_index = resp.node.modifiedIndex
            return updates
        end

        if fiber.time() < deadline then
            -- connection refused etc.
            fiber.sleep(session.connection.request_timeout)
        elseif err.http_code == 408 then
            -- timeout, no updates
            return {}
        else
            return nil, ClientError:new(err)
        end
    end
end

local client_mt = {
    __type = 'etcd2_client',
    __index = {
        longpoll = longpoll,
        get_session = get_session,
        drop_session = drop_session,
    },
}

local function new(cfg)
    checks({
        prefix = 'string',
        lock_delay = 'number',
        endpoints = '?table',
        username = '?string',
        password = '?string',
        request_timeout = 'number',
    })

    local client = {
        state_provider = 'etcd2',
        session = nil,
        cfg = table.deepcopy(cfg),
    }

    return setmetatable(client, client_mt)
end

return {
    new = new,
}
