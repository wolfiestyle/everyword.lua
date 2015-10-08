#!/usr/bin/env lua
local sqlite = require "lsqlite3"
local twitter = require "luatwit"
local lfs = require "lfs"

local script_name = arg[0]:match "[^/]+$"

local function parse_args()
    local parser = require "argparse" (script_name)
        :description "Tweets all words from a list in order."
    parser:option "--db"
        :description "Words database filename."
        :default "words.db"

    local cmd_create = parser:command "create"
        :description "Initializes a word database file."
    cmd_create:argument "words_file"
        :description "Text file with words (one per line)."
        :convert(io.open)

    local cmd_config = parser:command "config"
        :description "Sets config variables."
    cmd_config:option "-f" "--format"
        :description "Tweet format text (%s = the word)."

    local tw_login = parser:command "login"
        :description "Authorizes the client with Twitter."
    tw_login:option "-k" "--consumer-key"
        :description "Application consumer key."
    tw_login:option "-s" "--consumer-secret"
        :description "Application consumer secret."

    parser:command "logout"
        :description "Deletes the auth info from the database."

    parser:command "tweet"
        :description "Tweets the next word."

    local cmd_list = parser:command "list"
        :description "Outputs a list of the tweeted words."
    cmd_list:argument "word"
        :description "Word to search."
        :args "?"

    return parser:parse()
end

local function perror(...)
    io.stderr:write(...)
    io.stderr:write "\n"
end

---

local database = {}
database.__index = database

function database.open(filename)
    local self = {}

    local db, _, err = sqlite.open(filename)
    assert(db, err)
    self.db = db

    -- statement cache
    self.prepare = setmetatable({}, {
        __index = function(_self, sql)
            local st = db:prepare(sql)
            if st == nil then
                error(db:error_message(), 2)
            end
            _self[sql] = st
            return st
        end,
    })

    return setmetatable(self, database)
end

function database:init()
    if self:table_exists "words_db_version" then
        self:exec "SELECT required_v1 FROM words_db_version"
    else
        self:exec [[
CREATE TABLE words_db_version (
    required_v1
);
CREATE TABLE config (
    key TEXT NOT NULL PRIMARY KEY,
    val TEXT NOT NULL
);
CREATE TABLE words (
    id INTEGER PRIMARY KEY,
    word TEXT NOT NULL,
    tweet_id TEXT
);
]]
    end

    --self:exec "PRAGMA foreign_keys = ON"
end

function database:exec(...)
    if self.db:exec(...) ~= 0 then
        error(self.db:error_message())
    end
end

local function st_exec_0(db, st)
    if st:step() ~= sqlite.DONE then
        error(db:error_message())
    end
end

local function st_exec_1(db, st)
    local res = st:step()
    if res == sqlite.ROW then
        return st:get_uvalues()
    elseif res ~= sqlite.DONE then
        error(db:error_message())
    end
    return nil
end

function database:exec_0(sql, ...)
    local st = self.prepare[sql]
    st:reset()
    st:bind_values(...)
    return st_exec_0(self.db, st)
end

function database:exec_1u(sql, ...)
    local st = self.prepare[sql]
    st:reset()
    st:bind_values(...)
    return st_exec_1(self.db, st)
end

function database:table_exists(name)
    return self:exec_1u("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name) == 1
end

function database:get_config(key)
    return self:exec_1u("SELECT val FROM config WHERE key = ?", key)
end

function database:set_config(key, val)
    return self:exec_0("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)", key, val)
end

function database:unset_config(key)
    return self:exec_0("DELETE FROM config WHERE key = ?", key)
end

function database:get_word(id)
    return self:exec_1u("SELECT word FROM words WHERE id = ?", id)
end

function database:insert_word(word)
    return self:exec_0("INSERT INTO words (word) VALUES (?)", word)
end

function database:update_word(id, tweet_id)
    return self:exec_0("UPDATE words SET tweet_id = ? WHERE id = ?", tweet_id, id)
end

local oauth_names = { "consumer_key", "consumer_secret", "oauth_token", "oauth_token_secret" }

function database:load_keys()
    local keys = {}
    for _, name in ipairs(oauth_names) do
        keys[name] = self:get_config(name)
    end
    if not keys.oauth_token then
        perror("Error: Twitter keys not found.\nYou must login first with the '", script_name, " login' command.")
        os.exit(1)
    end
    return keys
end

function database:save_keys(ckey, csecret, token)
    self:exec "BEGIN"
    self:set_config("consumer_key", ckey)
    self:set_config("consumer_secret", csecret)
    self:set_config("oauth_token", token.oauth_token)
    self:set_config("oauth_token_secret", token.oauth_token_secret)
    self:exec "COMMIT"
end

---

local function ask(str)
    io.stderr:write(str)
    return io.read()
end

local function cmd_create(db, file)
    db:exec "BEGIN"
    for line in file:lines() do
        local word = line:match "^%a+"
        if word then
            db:insert_word(word)
        end
    end
    db:exec "COMMIT"
end

local function cmd_config(db, format)
    if format ~= nil then
        db:set_config("tweet_format", format)
    else
        perror("format: ", db:get_config "tweet_format" or "%s")
    end
end

local function cmd_login(db, ckey, csecret)
    ckey = ckey or db:get_config "consumer_key" or ask "consumer key: "
    csecret = csecret or db:get_config "consumer_secret" or ask "consumer secret: "
    local client = twitter.api.new{ consumer_key = ckey, consumer_secret = csecret }

    assert(client:oauth_request_token())
    perror("-- auth url: ", client:oauth_authorize_url())
    local pin = assert(ask("enter pin: "):match("%d+"), "invalid pin")
    local token = assert(client:oauth_access_token{ oauth_verifier = pin })
    db:save_keys(ckey, csecret, token)

    perror("-- logged in as ", token.screen_name)
end

local function cmd_logout(db)
    db:exec "PRAGMA secure_delete = true"
    db:exec "BEGIN"
    for _, name in ipairs(oauth_names) do
        db:unset_config(name)
    end
    db:exec "COMMIT"
end

local function cmd_tweet(db)
    local client = twitter.api.new(db:load_keys())
    local last_id = tonumber(db:get_config "last_word_id") or 0
    local tweet_fmt = db:get_config "tweet_format" or "%s"

    last_id = last_id + 1
    local word = db:get_word(last_id)
    if word then
        local message = tweet_fmt:format(word)
        --print("-- tweeting: " .. message)
        local tweet, err = client:tweet{ status = message }
        local tweet_id
        if tweet == nil then
            if err._type == "error" and err:code() == 187 then -- status duplicate
                tweet_id = 0 -- we don't know the id, but it's there
            else
                error(tostring(err))
            end
        else
            tweet_id = tweet.id_str
        end
        db:set_config("last_word_id", tostring(last_id))
        db:update_word(last_id, tweet_id)
    end
end

local function cmd_list(db, search)
    local cond = search and " AND word LIKE ?" or ""
    local st = db.prepare["SELECT id, word, tweet_id FROM words WHERE tweet_id NOT NULL" .. cond]
    if search then
        st:bind_values(search)
    end
    for id, word, tweet_id in st:urows() do
        print(("%d: %s  -- tweet %s"):format(id, word, tweet_id))
    end
end

---

local args = parse_args()

if lfs.attributes(args.db) then
    if args.create then
        perror("Error: output file '", args.db, "' already exists.")
        os.exit(1)
    end
else
    if not args.create then
        perror("Error: file '", args.db, "' not found.\nUse the 'create' command to build a database.")
        os.exit(1)
    end
end

local db = database.open(args.db)
db:init()

if args.create then
    cmd_create(db, args.words_file)
elseif args.config then
    cmd_config(db, args.format)
elseif args.tweet then
    cmd_tweet(db)
elseif args.login then
    cmd_login(db, args.consumer_key, args.consumer_secret)
elseif args.logout then
    cmd_logout(db)
elseif args.list then
    cmd_list(db, args.word)
end
