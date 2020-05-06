-- TODO
-- etcd_client implementation
-- lock_delay location
-- connection status
-- set_leaders duplicates


local fiber = require('fiber')
local checks = require('checks')
local errors = require('errors')
local netbox = require('net.box')
local json = require('json')
local fio = require('fio')

local etcd = require('moonlibs.etcd') -- TODO etcd_client implementation
local etcd_client = etcd:new{}
etcd_client:discovery()

local ClientError  = errors.new_class('ClientError')
local SessionError = errors.new_class('SessionError')
local EtcdError = errors.new_class('EtcdError')

local function acquire_lock(session, lock_args) --TODO /keys/coordinator json.encode(lock_args)
    checks('etcd_session', 'table')
    assert(session.connection ~= nil)

    local lock_data = json.encode({uuid = lock_args[1], uri = lock_args[2]})

    if session.lock_acquired == true then
        local lock = etcd_client:request('PUT', '/keys/coordinator',
            {
                value = lock_data,
                prevValue = lock_data,
                ttl = session.lock_delay
            })

        if lock.errorCode ~= nil then
            -- probably lock was stolen
            session.lock_acquired = false
            return nil, SessionError:new('The lock was stolen')
        end

        return true
    end

    local lock = etcd_client:request('PUT', '/keys/coordinator',
        {
            value = lock_data,
            prevExist = false,
            ttl = session.lock_delay
        })

    if lock.errorCode ~= nil then
        -- probably lock is taken
        session.lock_acquired = false
        return false
    end

    session.uuid = lock_args[1]
    session.uri = lock_args[2]
    session.lock_acquired = true
    return true
end

local function get_lock_delay(session) --TODO lock_delay
    return session.lock_delay
end

local function set_leaders(session, updates) --TODO /keys/leaders/${replicaset_uuid} leader_uuid
    checks('etcd_session', 'table')
    assert(session.connection ~= nil)

    if not session:is_locked() then -- TODO maybe in the for loop?
        return nil, SessionError:new('You are not holding the lock')
    end

    for _, leader in ipairs(updates) do
        local replicaset_uuid, instance_uuid = unpack(leader)
        etcd_client:request('PUT',string.format('/keys/leaders/%s', replicaset_uuid),
            {
                value = instance_uuid
            })
    end
    return true
end

local function get_leaders(session) -- TODO longpoll leaders
    checks('etcd_session')
    assert(session.connection ~= nil)

    local leaders = etcd_client:request('GET', '/keys/leaders', {})

    leaders = leaders.node.nodes
    local ret = {}
    for _, replicaset in ipairs(leaders) do
        local replicaset_uuid = fio.basename(replicaset.key)
        ret[replicaset_uuid] = replicaset.value
    end

    return ret
end

local function get_coordinator(session)
    checks('etcd_session')
    assert(session.connection ~= nil)

    local lock = etcd_client:request('GET', '/keys/coordinator', {})

    if lock.errorCode ~= nil then

        if lock.errorCode == 100 then
            -- there is no coordinator
            return nil
        end

        return nil, SessionError:new(lock.message)

    end

    return json.decode(lock.node.value)

end

local function is_locked(session)

    local lock_data = json.encode({uuid = session.uuid, uri = session.uri})

    local lock = etcd_client:request(
        'PUT',
        '/keys/coordinator',
        {
            value = lock_data,
            prevValue = lock_data,
            ttl = session.lock_delay -- after the check lock is refreshed
        })

    if lock.errorCode ~= nil then
        return false
    end

    return true
end

local function drop(session)
    checks('etcd_session')
    assert(session.connection ~= nil)

    session.lock_acquired = false
    if session.uri ~= nil and session.uuid ~= nil then
        local resp = etcd_client:request('DELETE', '/keys/coordinator',
        {
            prevValue = json.encode({uuid = session.uuid, uri = session.uri})
        })

        if resp.errorCode ~= nil then
            -- lock in another session
            return false
        end

        session.uri = nil
        session.uuid = nil
        return true
    else
        return true -- if lock is stolen, session is dropped?
    end
end

local session_mt = {
    __type = 'etcd_session',
    __index = {
        --is_alive = is_alive,
        is_locked = is_locked,
        --is_connected = is_connected,
        acquire_lock = acquire_lock,
        set_leaders = set_leaders,
        get_leaders = get_leaders,
        get_lock_delay = get_lock_delay,
        get_coordinator = get_coordinator,
        drop = drop,
    },
}

local function get_session(client)
    checks('etcd_client')

    if client.session ~= nil then
        return client.session
    end

    local connection = 1 -- TODO connection's fate

    local session = {
        lock_acquired = false,
        call_timeout = client.call_timeout,
        connection = connection,
        lock_delay = client.lock_delay,
    }
    client.session = setmetatable(session, session_mt)
    return client.session
end

local client_mt = {
    __type = 'etcd_client',
    __index = {
        --longpoll = longpoll,
        get_session = get_session,
        --drop_session = drop_session,
    },
}

local function new(opts)
    checks({
        uri = 'string',
        password = 'string',
        call_timeout = 'number',
        lock_delay = 'number' -- TODO lock_delay's fate
    })

    local client = {
        state_provider = 'tarantool',
        session = nil,
        uri = opts.uri,
        password = opts.password,
        lock_delay = opts.lock_delay, --TODO lock_delay's fate
        call_timeout = opts.call_timeout,
    }
    return setmetatable(client, client_mt)
end


return {
    new = new,
}
