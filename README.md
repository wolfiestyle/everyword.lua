# everyword.lua

"Every word" twitter bot engine written in Lua.

## Dependencies

- argparse
- lfs
- lsqlite3
- luatwit

## Usage

Initialize the database:

    ./everyword.lua create /usr/share/dict/words    # creates words.db
    ./everyword.lua config --format 'something %s'  # tweet format string
    ./everyword.lua login                           # twitter app keys and login
    ./everyword.lua tweet                           # tweet a word, state is saved on db

Then run periodically from cron:

    crontab -e      # insert the line below
    */15 * * * * cd ~/bots/everyword && ./everyword.lua tweet
