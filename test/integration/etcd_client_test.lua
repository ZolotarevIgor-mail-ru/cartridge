local fio = require('fio')
local uuid = require('uuid')
local fiber = require('fiber')
local socket = require('socket')
local utils = require('cartridge.utils')
local etcd2_client = require('cartridge.etcd2-client')
local t = require('luatest')
local g = t.group('etcd_client')

local etcd2 = require('cartridge.etcd2')

local helpers = require('test.helper')

local function create_connection()
    return etcd2.connect(nil, {
        prefix = 'etcd2_client_test',
        username = 'client',
        password = g.password,
        request_timeout = 1,
    })
end

local function create_client()
    return etcd2_client.new({
        prefix = 'etcd2_client_test',
        lock_delay = g.lock_delay,
        endpoints = {
            'http://127.0.0.1:4001',
            'http://127.0.0.1:2379',
        },
        username = 'client',
        password = g.password,
        request_timeout = 1,
    })
end

g.before_all(function()
    g.password = require('digest').urandom(6):hex()
    g.lock_delay = 40

    g.etcd2_connection = create_connection()
end)

g.after_each(function()
    g.etcd2_connection:request('DELETE', '/lock', {})
    g.etcd2_connection:request('DELETE', '/leaders', {})
end)


function g.test_locks()
    local c1 = create_client():get_session()
    local c2 = create_client():get_session()
    local kid = uuid.str()

    t.assert_equals(
        c1:acquire_lock({uuid = kid, uri ='localhost:9'}),
        true
    )
    t.assert_equals(
        c1:get_coordinator(),
        {uuid = kid, uri = 'localhost:9'}
    )

    t.assert_equals(
        c2:acquire_lock({uuid = uuid.str(), uri = 'localhost:11'}),
        false
    )

    local ok, err = c2:set_leaders({{'A', 'a1'}})
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'You are not holding the lock'
    })

    t.assert_equals(
        c2:get_coordinator(),
        {uuid = kid, uri = 'localhost:9'}
    )

    t.assert(c1:drop(), true)

    local kid = uuid.str()
    helpers.retrying({}, function()
        t.assert_equals({c2:get_coordinator()}, {nil})
    end)

    t.assert_equals(
        c2:acquire_lock({uuid = kid, uri = 'localhost:11'}),
        true
    )
    t.assert_equals(
        c2:get_coordinator(),
        {uuid = kid, uri = 'localhost:11'}
    )
end

function g.test_appointments()
    local c = create_client():get_session()
    local kid = uuid.str()
    t.assert_equals(
        c:acquire_lock({uuid = kid, uri = 'localhost:9'}),
        true
    )

    t.assert_equals(
        c:set_leaders({{'A', 'a1'}, {'B', 'b1'}}),
        true
    )

    t.assert_equals(
        c:get_leaders(),
        {A = 'a1', B = 'b1'}
    )

    local ok, err = c:set_leaders({{'A', 'a2'}, {'A', 'a3'}})
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'Duplicate key in updates'
    })
end

function g.test_longpolling()
    local c1 = create_client():get_session()
    local kid = uuid.str()
    t.assert_equals(
        c1:acquire_lock({uuid = kid, uri = 'localhost:9'}),
        true
    )
    c1:set_leaders({{'A', 'a1'}, {'B', 'b1'}})

    local client = create_client()
    local function async_longpoll()
        local chan = fiber.channel(1)
        fiber.new(function()
            local ret, err = client:longpoll(0.2)
            chan:put({ret, err})
        end)
        return chan
    end

    t.assert_equals(client:longpoll(0), {A = 'a1', B = 'b1'})

    local chan = async_longpoll()
    t.assert(c1:set_leaders({{'A', 'a2'}}), true)
    t.assert_equals(chan:get(0.1), {{A = 'a2'}})

    local chan = async_longpoll()
    -- there is no data in channel
    t.assert_equals(chan:get(0.1), nil)

    -- data recieved
    t.assert_equals(chan:get(0.2), {{}}) -- TODO
end

function g.test_client_drop_session()
    local client = create_client()
    local session = client:get_session()
    t.assert_equals(session:is_alive(), true)
    t.assert_is(client:get_session(), session)

    local ok = session:acquire_lock({uuid = 'uuid', uri = 'uri'})
    t.assert_equals(ok, true)
    t.assert_equals(session:is_alive(), true)
    t.assert_equals(session:is_locked(), true)
    t.assert_is(client:get_session(), session)

    client:drop_session()

    local ok, err = session:get_leaders()
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'Session is dropped',
    })

    -- dropping session releases lock and make it dead
    t.assert_equals(session:is_alive(), false)
    t.assert_equals(session:is_locked(), false)

    -- dropping session is idempotent
    client:drop_session()
    t.assert_equals(session:is_alive(), false)
    t.assert_equals(session:is_locked(), false)

    t.assert_is_not(client:get_session(), session)
end

function g.test_client_session()
    -- get_session always returns alive one
    local client = create_client()
    local session = client:get_session()
    t.assert_equals(session:is_alive(), true)
    t.assert_is(client:get_session(), session)

    local ok = session:acquire_lock({uuid = 'uuid', uri = 'uri'})
    t.assert_equals(ok, true)
    t.assert_equals(session:is_alive(), true)
    t.assert_equals(session:is_locked(), true)
    t.assert_is(client:get_session(), session)

    -- get_session creates new session if old one is dead
    g.etcd2_connection:request('DELETE', '/lock', {})
    t.helpers.retrying({}, function()
        t.assert_equals(session:acquire_lock({uuid = 'uuid', uri = 'uri'}), nil)
    end)

    local ok, err = session:get_leaders()
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'Session is dropped',
    })
    t.assert_is_not(client:get_session(), session)

    -- session looses lock if connection is interrupded
    t.assert_equals(session:is_alive(), false)
    t.assert_equals(session:is_locked(), false)
end
