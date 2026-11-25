#!/usr/bin/env bash

if [ "$#" -lt 1 ]; then
    echo "Missing new version specifier"
    exit 1
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
NEW_VERSION="$1"
RPM_VERSION=`echo $NEW_VERSION | sed 's/-/~/g'`
NOTICE_LINE="# NOTE: keep this part at the bottom of the file, do not change this line"

replace_file() {
    local file=$1 expression=$2 temporary mode status
    temporary=$(mktemp "$file.XXXXXX") || return
    if sed -E "$expression" "$file" > "$temporary"; then
        mode=$(python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$file") || {
            rm -f "$temporary"
            return 1
        }
        chmod "$mode" "$temporary" || {
            rm -f "$temporary"
            return 1
        }
        mv "$temporary" "$file" || {
            rm -f "$temporary"
            return 1
        }
    else
        status=$?
        rm -f "$temporary"
        return "$status"
    fi
}

echo "Updating version in Cargo.toml"
replace_file "$PROJECT_DIR/Cargo.toml" 's/^version[[:space:]]*=[[:space:]]*".*"/version = "'"$NEW_VERSION"'"/'

echo "Updating workspace crate versions in Cargo.toml"
tmp_file="$PROJECT_DIR/Cargo.toml.tmp"
replace_flag=0
while IFS= read -r line; do
    if [ $replace_flag -eq 1 ]; then
        line=$(printf '%s\n' "$line" | sed -E 's/version[[:space:]]*=[[:space:]]*"[^"]*"/version = "'"$NEW_VERSION"'"/g')
    fi

    if [ "$line" = "$NOTICE_LINE" ]; then
        replace_flag=1
    fi

    echo "$line" >> "$tmp_file"
done < "$PROJECT_DIR/Cargo.toml"
mv "$tmp_file" "$PROJECT_DIR/Cargo.toml"

echo "Updating rpm version in Cargo.toml"
replace_file "$PROJECT_DIR/ntpd/Cargo.toml" 's/^version = .* #MARKER: RPM-VERSION/version = "'"$RPM_VERSION"'" #MARKER: RPM-VERSION/'

echo "Updating version in man pages"
replace_file "$PROJECT_DIR/docs/man/ntp-ctl.8.md" 's/^title: NTP-CTL(8) ntpd-rs .*/title: NTP-CTL(8) ntpd-rs '"$NEW_VERSION"' | ntpd-rs/'
replace_file "$PROJECT_DIR/docs/man/ntp-daemon.8.md" 's/^title: NTP-DAEMON(8) ntpd-rs .*/title: NTP-DAEMON(8) ntpd-rs '"$NEW_VERSION"' | ntpd-rs/'
replace_file "$PROJECT_DIR/docs/man/ntp-metrics-exporter.8.md" 's/^title: NTP-METRICS-EXPORTER(8) ntpd-rs .*/title: NTP-METRICS-EXPORTER(8) ntpd-rs '"$NEW_VERSION"' | ntpd-rs/'
replace_file "$PROJECT_DIR/docs/man/ntp.toml.5.md" 's/^title: NTP.TOML(5) ntpd-rs .*/title: NTP.TOML(5) ntpd-rs '"$NEW_VERSION"' | ntpd-rs/'

echo "Rebuilding precompiled man pages"
utils/generate-man.sh

echo "Rebuilding project"
(cd $PROJECT_DIR && cargo clean && cargo build --release)

echo "!!! Version changes complete, make sure that the changelog is synchronized"
