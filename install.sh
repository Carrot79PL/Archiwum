#!/bin/zsh
# Instaluje Archiwum w ~/Applications i rejestruje usługi Findera (menu kontekstowe).
set -e
cd "$(dirname "$0")"
./build.sh
mkdir -p ~/Applications
pkill -x Archiwum 2>/dev/null || true
rm -rf ~/Applications/Archiwum.app
ditto --noextattr --noqtn --norsrc Archiwum.app ~/Applications/Archiwum.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Archiwum.app
/System/Library/CoreServices/pbs -update
echo "Zainstalowano: ~/Applications/Archiwum.app (usługi zarejestrowane)"
