local t = require('luatest')
local g = t.group()

local fio = require('fio')
local uuid = require('uuid')
local fiber = require('fiber')
local httpc = require('http.client')
local etcd2_client = require('cartridge.etcd2-client')

local helpers = require('test.helper')

local URI = 'http://127.0.0.1:14001'

local function create_client()
    return etcd2_client.new({
        prefix = 'etcd2_client_test',
        lock_delay = g.lock_delay,
        endpoints = {URI},
        request_timeout = 1,
    })
end

g.before_each(function()
    local etcd_path = os.getenv('ETCD_PATH')
    t.skip_if(
        etcd_path == nil,
        'Missing etcd. Skipping'
    )

    g.datadir = fio.tempdir()
    g.etcd = t.Process:start(etcd_path, {
        '--data-dir', g.datadir,
        '--listen-peer-urls', 'http://localhost:17001',
        '--listen-client-urls', URI,
        '--advertise-client-urls', URI,
    })
    helpers.retrying({}, function()
        local resp = httpc.put(URI .. '/v2/keys/hello?value=world')
        assert(resp.status == 200)
        require('log').info(
            httpc.get(URI ..'/version').body
        )
    end)

    g.password = require('digest').urandom(6):hex()
    g.lock_delay = 40
end)

g.after_each(function()
    g.etcd:kill()
    fio.rmtree(g.datadir)
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
    t.assert_equals(chan:get(0.1), {{A = 'a2', B = 'b1'}})

    local chan = async_longpoll()
    -- there is no data in channel
    t.assert_equals(chan:get(0.1), nil)

    -- data recieved
    t.assert_equals(chan:get(0.2), {{}})
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

function g.test_outage()
    -- Test case:
    -- 1. Coordinator C1 acquires a lock and freezes;
    -- 2. Lock delay expires and stateboard allows C2 to acquire it again;
    -- 3. C2 writes some decisions and releases a lock;
    -- 4. C1 comes back;
    -- Goal: C1 must be informed on his outage

    g.lock_delay = 0

    local payload = {uuid = uuid.str(), uri = 'localhost:9'}

    local c1 = create_client():get_session()
    t.assert_equals(
        {c1:acquire_lock(payload)},
        {true}
    )
    t.assert_equals(
        -- C1 can renew expired lock if it wasn't stolen yet
        {c1:acquire_lock(payload)},
        {true}
    )

    local c2 = create_client():get_session()
    t.helpers.retrying({}, function()
        t.assert_equals(
            {c2:acquire_lock(payload)},
            {true}
        )
    end)

    c2:drop()

    -- C1 can't renew lock after it was stolen by C2
    local ok, err = c1:acquire_lock(payload)
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'The lock was stolen'
    })

    local ok, err = c1:set_leaders({})
    t.assert_equals(ok, nil)
    t.assert_covers(err, {
        class_name = 'SessionError',
        err = 'You are not holding the lock'
    })
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
    httpc.delete(URI .. '/v2/keys/etcd2_client_test/lock')

    t.helpers.retrying({}, function()
        t.assert_equals(
            session:acquire_lock({uuid = 'uuid', uri = 'uri'}),
            nil
        )
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