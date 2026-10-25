fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'sw_tow'
author 'Shiftworks'
description 'Shiftworks Tow & Impound: multiplayer towing job with player calls and an impound yard'
version '0.1.0'
license 'GPL-3.0-or-later'
repository ''  -- https://github.com/<owner>/sw_tow once published; enables the update check

ox_lib 'locale'

dependencies {
    '/onesync',
    'ox_lib',
    'ox_target',
    'oxmysql',
}

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'config.lua',
    'locales/*.json',
    'shared/*.lua',
    'bridge/loader.lua',
    'bridge/**/client.lua',
    'client/*.lua',
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/fonts/*.woff2',
}
