#!/bin/sh
# luci-app-etherwake-nfqueue.sh — install or uninstall luci-app-etherwake-nfqueue on OpenWrt
# Usage: sh luci-app-etherwake-nfqueue.sh install
#        sh luci-app-etherwake-nfqueue.sh uninstall
set -e

BOLD='\033[1m'; GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'
info()  { printf "${BOLD}>>> %s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}    ok: %s${RESET}\n" "$*"; }
warn()  { printf "${RED}    warn: %s${RESET}\n" "$*"; }

do_uninstall() {
    info "Stopping wol-trigger-nft-gen"
    /etc/init.d/wol-trigger-nft-gen stop 2>/dev/null; ok "stopped"

    info "Disabling wol-trigger-nft-gen"
    /etc/init.d/wol-trigger-nft-gen disable 2>/dev/null; ok "disabled"

    info "Removing wol-trigger-nft-gen init script"
    rm -f /etc/init.d/wol-trigger-nft-gen; ok "removed"

    info "Removing nft file"
    rm -f /var/run/etherwake-nfqueue.nft; ok "removed"

    info "Removing LuCI view"
    rm -f /www/luci-static/resources/view/wol-trigger.js; ok "removed"

    info "Removing LuCI menu entry"
    rm -f /usr/share/luci/menu.d/luci-app-etherwake-nfqueue.json; ok "removed"

    info "Removing rpcd ACL"
    rm -f /usr/share/rpcd/acl.d/luci-app-etherwake-nfqueue.json; ok "removed"

    info "Reloading rpcd"
    /etc/init.d/rpcd reload; ok "reloaded"

    printf "\n${GREEN}${BOLD}Uninstalled.${RESET}\n"
    printf "  /etc/config/etherwake-nfqueue and firewall UCI kept intact.\n"
}

FORCE=0

do_install() {

# ── 1. Package ────────────────────────────────────────────────────────────────
info "Installing etherwake-nfqueue"
if apk info -e etherwake-nfqueue >/dev/null 2>&1; then
    ok "already installed"
else
    apk update && apk add etherwake-nfqueue
    ok "installed"
fi

# ── 2. UCI config: etherwake-nfqueue ─────────────────────────────────────────
info "Setting up /etc/config/etherwake-nfqueue"
if [ "$FORCE" = "1" ] || [ ! -f /etc/config/etherwake-nfqueue ]; then
    cat > /etc/config/etherwake-nfqueue << 'UCI'
config etherwake-nfqueue 'setup'
	option interface 'br-lan'
	option chain 'forward_lan'
	option nft_rate '3/minute'
	option nft_burst '1'
	option nft_dest_port '3389'
	option sudo 'off'
	option debug 'off'
UCI
    ok "created"
else
    ok "already exists, not overwritten"
fi

# ── 3. Firewall nftables include ──────────────────────────────────────────────
info "Setting up firewall include 'wol-trigger'"
if [ "$FORCE" != "1" ] && uci -q get firewall.wol-trigger >/dev/null; then
    ok "firewall.wol-trigger already configured"
else
    uci batch << 'UCIEOF'
set firewall.wol-trigger=include
set firewall.wol-trigger.type='nftables'
set firewall.wol-trigger.path='/var/run/etherwake-nfqueue.nft'
set firewall.wol-trigger.position='ruleset-append'
set firewall.wol-trigger.enabled='0'
commit firewall
UCIEOF
    ok "created (disabled by default — enable via LuCI)"
fi

# ── 4. Empty nft placeholder ─────────────────────────────────────────────────
info "Ensuring /var/run/etherwake-nfqueue.nft exists"
touch /var/run/etherwake-nfqueue.nft
ok "created"

# ── 5. LuCI: ACL ─────────────────────────────────────────────────────────────
info "Installing rpcd ACL"
mkdir -p /usr/share/rpcd/acl.d
cat > /usr/share/rpcd/acl.d/luci-app-etherwake-nfqueue.json << 'JSON'
{
  "luci-app-etherwake-nfqueue": {
    "description": "Grant UCI access for WoL Trigger",
    "read": {
      "uci": ["firewall", "etherwake-nfqueue"],
      "file": { "/var/run/etherwake-nfqueue.nft": ["read"] }
    },
    "write": {
      "uci": ["firewall", "etherwake-nfqueue"]
    }
  }
}
JSON
ok "written"

# ── 6. LuCI: menu entry ───────────────────────────────────────────────────────
info "Installing LuCI menu entry"
mkdir -p /usr/share/luci/menu.d
cat > /usr/share/luci/menu.d/luci-app-etherwake-nfqueue.json << 'JSON'
{
  "admin/services/wol-trigger": {
    "title": "WoL Trigger",
    "order": 60,
    "action": {
      "type": "view",
      "path": "wol-trigger"
    },
    "depends": {
      "acl": ["luci-app-etherwake-nfqueue"]
    }
  }
}
JSON
ok "written"

# ── 7. LuCI: JS view ─────────────────────────────────────────────────────────
info "Installing LuCI view"
mkdir -p /www/luci-static/resources/view
cat > /www/luci-static/resources/view/wol-trigger.js << 'JS'
'use strict';
'require view';
'require form';
'require uci';
'require network';
'require ui';

return view.extend({
    maps: [],

    load: function() {
        return Promise.all([
            uci.load(['firewall', 'etherwake-nfqueue']),
            network.getDevices()
        ]);
    },

    render: function(data) {
        var self = this;
        var devices = data[1];
        var devnames = devices.map(function(d) { return d.getName(); }).sort();
        var mfw, m, mdef, s, o;

        /* derive fw4 chain names from firewall zones */
        var chains = [];
        uci.sections('firewall', 'zone').forEach(function(z) {
            if (!z.name) return;
            ['forward', 'input', 'output'].forEach(function(dir) {
                chains.push(dir + '_' + z.name);
            });
        });
        chains.sort();

        /* ── Firewall include ── */
        mfw = new form.Map('firewall', _('WoL Trigger'));

        s = mfw.section(form.NamedSection, 'wol-trigger', 'include', '',
            _('Wake on LAN triggered by network port.'));
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('Enable WoL Trigger'));
        o.rmempty = false;
        o.default = '0';

        /* read global defaults for use as per-target field defaults */
        var defIface = uci.get('etherwake-nfqueue', 'setup', 'interface')   || 'br-lan';
        var defChain = uci.get('etherwake-nfqueue', 'setup', 'chain')       || 'forward_lan';
        var defIif   = uci.get('etherwake-nfqueue', 'setup', 'nft_iifname') || '';
        var defOif   = uci.get('etherwake-nfqueue', 'setup', 'nft_oifname') || '';
        var defPort  = uci.get('etherwake-nfqueue', 'setup', 'nft_dest_port') || '3389';
        var defRate  = uci.get('etherwake-nfqueue', 'setup', 'nft_rate')    || '3/minute';
        var defBurst = uci.get('etherwake-nfqueue', 'setup', 'nft_burst')   || '1';

        /* ── Targets map ── */
        m = new form.Map('etherwake-nfqueue', _('Wake on LAN Targets'),
            _('Configuring hosts to wake up automatically via port triggering.'));

        /* ── Targets ── */
        s = m.section(form.GridSection, 'target', _('Targets'));
        s.addremove = true;
        s.sortable  = false;
        s.modal     = true;
        s.anonymous = true;

        s.tab('general',  _('General'));
        s.tab('advanced', _('Advanced Settings'));

        /* General tab — also creates grid columns (no modalonly) */
        o = s.taboption('general', form.Flag, 'enabled', _('On'));
        o.rmempty  = false;
        o.default  = '1';

        o = s.taboption('general', form.Value, 'name', _('Name'));
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'mac', _('MAC Address'));
        o.datatype  = 'macaddr';
        o.rmempty   = false;
        o.modalonly = true;

        o = s.taboption('general', form.Value, 'nft_dest_ip', _('Dest IP'));
        o.datatype = 'ip4addr';
        o.rmempty  = false;

        o = s.taboption('general', form.Value, 'nft_dest_port', _('Port'));
        o.datatype = 'port';
        o.default  = defPort;

        /* Advanced Settings tab */
        o = s.taboption('advanced', form.Value, 'interface', _('Send Interface'),
            _('Interface used by etherwake to send the magic packet'));
        o.default   = defIface;
        o.modalonly = true;
        devnames.forEach(function(n) { o.value(n); });

        o = s.taboption('advanced', form.Value, 'chain', _('Chain'));
        o.default   = defChain;
        o.modalonly = true;
        chains.forEach(function(c) { o.value(c); });

        o = s.taboption('advanced', form.Value, 'nft_iifname', _('Incoming Interface'));
        o.modalonly = true;
        devnames.forEach(function(n) { o.value(n); });

        o = s.taboption('advanced', form.Value, 'nft_oifname', _('Outgoing Interface'));
        o.modalonly = true;
        devnames.forEach(function(n) { o.value(n); });

        o = s.taboption('advanced', form.Value, 'nft_rate', _('Rate Limit'));
        o.default   = defRate;
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'nft_burst', _('Burst'));
        o.default   = defBurst;
        o.datatype  = 'uinteger';
        o.modalonly = true;

        o = s.taboption('advanced', form.Flag, 'broadcast', _('Broadcast'),
            _('Send magic packet to broadcast address'));
        o.rmempty   = false;
        o.default   = '0';
        o.modalonly = true;

        o = s.taboption('advanced', form.Value, 'password', _('Password'),
            _('Set wake password'));
        o.modalonly = true;

        o = s.taboption('advanced', form.Flag, 'debug', _('Debug'),
            _('Log nft match to syslog and pass <code>-D</code> to etherwake-nfqueue'));
        o.rmempty   = false;
        o.default   = '0';
        o.modalonly = true;

        /* ── Global Defaults map (rendered into Advanced Settings page tab) ── */
        mdef = new form.Map('etherwake-nfqueue', '');

        var sd = mdef.section(form.NamedSection, 'setup', 'etherwake-nfqueue', _('Global Defaults'),
            _('Default values used when a target leaves a field blank.'));
        sd.addremove = false;

        o = sd.option(form.Value, 'interface', _('Send Interface'));
        o.default = 'br-lan';
        o.rmempty = false;
        devnames.forEach(function(n) { o.value(n); });

        o = sd.option(form.Value, 'chain', _('Chain'));
        o.default = 'forward_lan';
        o.rmempty = false;
        chains.forEach(function(c) { o.value(c); });

        o = sd.option(form.Value, 'nft_iifname', _('Incoming Interface'));
        devnames.forEach(function(n) { o.value(n); });

        o = sd.option(form.Value, 'nft_oifname', _('Outgoing Interface'));
        devnames.forEach(function(n) { o.value(n); });

        o = sd.option(form.Value, 'nft_dest_port', _('Default Port'));
        o.datatype = 'port';
        o.default  = '3389';
        o.rmempty  = false;

        o = sd.option(form.Value, 'nft_rate', _('Rate Limit'),
            _('e.g. <code>3/minute</code>'));
        o.default = '3/minute';
        o.rmempty = false;

        o = sd.option(form.Value, 'nft_burst', _('Burst'));
        o.datatype = 'uinteger';
        o.default  = '1';
        o.rmempty  = false;

        self.maps = [mfw, m, mdef];

        return Promise.all([mfw.render(), m.render(), mdef.render()]).then(function(nodes) {
            var view = E([], [
                nodes[0],
                E('div', {}, [
                    E('div', { 'data-tab': 'targets',  'data-tab-title': _('Targets') },          [ nodes[1] ]),
                    E('div', { 'data-tab': 'advanced', 'data-tab-title': _('Advanced Settings') }, [ nodes[2] ])
                ])
            ]);
            ui.tabs.initTabGroup(view.lastElementChild.childNodes);
            return view;
        });
    },

    handleSave: function() {
        return Promise.all(this.maps.map(function(m) { return m.save(); }));
    },

    handleSaveApply: function(ev) {
        return this.handleSave(ev).then(function() {
            return L.ui.changes.apply(true);
        });
    },

    handleReset: function() {
        return Promise.all(this.maps.map(function(m) { return m.reset(); }));
    }
});
JS
ok "written"

# ── 8. procd init script ──────────────────────────────────────────────────────
info "Installing wol-trigger-nft-gen init script"
cat > /etc/init.d/wol-trigger-nft-gen << 'INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=15
STOP=01

gen_nft() {
    . /lib/functions.sh

    local NFT_FILE="/var/run/etherwake-nfqueue.nft"
    > "$NFT_FILE"
    local counter=0
    local dirty=0

    handle_target() {
        local cfg="$1"
        local enabled debug name chain nft_iifname nft_oifname nft_dest_ip nft_dest_port nft_rate nft_burst

        config_get_bool enabled "$cfg" enabled 1
        [ "$enabled" = "1" ] || return

        counter=$((counter + 1))

        # auto-assign queue number by position; only write back if changed
        local stored_qnum
        config_get stored_qnum "$cfg" nfqueue_num ""
        if [ "$stored_qnum" != "$counter" ]; then
            uci set "etherwake-nfqueue.$cfg.nfqueue_num=$counter"
            dirty=1
        fi

        local def_chain def_port def_rate def_burst
        config_get def_chain setup chain         "forward_lan"
        config_get def_port  setup nft_dest_port "3389"
        config_get def_rate  setup nft_rate      "3/minute"
        config_get def_burst setup nft_burst     "1"

        config_get_bool debug    "$cfg" debug 0
        config_get name          "$cfg" name
        config_get chain         "$cfg" chain         "$def_chain"
        config_get nft_iifname   "$cfg" nft_iifname   ""
        config_get nft_oifname   "$cfg" nft_oifname   ""
        config_get nft_dest_ip   "$cfg" nft_dest_ip
        config_get nft_dest_port "$cfg" nft_dest_port "$def_port"
        config_get nft_rate      "$cfg" nft_rate      "$def_rate"
        config_get nft_burst     "$cfg" nft_burst     "$def_burst"

        [ -n "$nft_dest_ip" ] || return

        local iif_stmt="" oif_stmt="" log_stmt=""
        [ -n "$nft_iifname" ] && iif_stmt="iifname \"$nft_iifname\" "
        [ -n "$nft_oifname" ] && oif_stmt="oifname \"$nft_oifname\" "
        [ "$debug" = "1" ]    && log_stmt="log prefix \"WoL $name: \" "

        printf 'insert rule inet fw4 %s %s%sip daddr %s tcp dport %s ct state new limit rate %s burst %s packets counter %squeue num %s bypass comment "Wake %s on %s"\n' \
            "$chain" "$iif_stmt" "$oif_stmt" "$nft_dest_ip" "$nft_dest_port" \
            "$nft_rate" "$nft_burst" "$log_stmt" "$counter" "$name" "$nft_dest_port" >> "$NFT_FILE"
    }

    config_load etherwake-nfqueue
    config_foreach handle_target target

    # write back queue assignments only when something changed;
    # the resulting re-trigger finds all values correct → no further commit
    if [ "$dirty" = "1" ]; then
        uci commit etherwake-nfqueue
        /etc/init.d/etherwake-nfqueue restart
    fi

    local wol_enabled
    wol_enabled=$(uci -q get firewall.wol-trigger.enabled)
    [ "$wol_enabled" = "1" ] && /etc/init.d/firewall reload
}

start_service() { gen_nft; }
reload_service() { gen_nft; }

service_triggers() {
    procd_add_reload_trigger "etherwake-nfqueue"
}
INIT
chmod +x /etc/init.d/wol-trigger-nft-gen
ok "written"

# ── 9. etherwake-nfqueue init script (per-target debug + clean up global debug)
info "Patching etherwake-nfqueue init script"
cat > /etc/init.d/etherwake-nfqueue << 'EWAKE'
#!/bin/sh /etc/rc.common
#
# Copyright (C) 2019 Mister Benjamin <144dbspl@gmail.com>

NAME='etherwake-nfqueue'

START=60
USE_PROCD=1

PROGRAM=${NAME}

start_service()
{
    local value

    config_load ${NAME}

    config_get_bool value setup sudo 0
    [ "${value}" -ne 0 ] && PROGRAM="sudo ${PROGRAM}"

    config_foreach start_instance target
}

start_instance()
{
    local section="$1"
    local value name mac

    config_get_bool value "${section}" enabled 1
    [ "${value}" -ne 1 ] && return 0

    config_get value "${section}" name
    [ -z "${value}" ] && value="{section}"
    name=${value}

    config_get mac "${section}" mac
    [ -z "${mac}" ] && {
        echo "${initscript}: Target ${name} has no MAC address"
        return 1
    }

    procd_open_instance ${name}
    procd_set_param command ${PROGRAM}
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1

    config_get_bool value "${section}" broadcast 0
    [ "${value}" -ne 0 ] && procd_append_param command -b

    config_get value "${section}" interface ""
    [ -z "${value}" ] && config_get value setup interface ""
    [ -n "${value}" ] && procd_append_param command -i "${value}"

    config_get value "${section}" password
    [ -n "${value}" ] && procd_append_param command -p "${value}"

    config_get_bool value "${section}" debug 0
    [ "${value}" -ne 0 ] && procd_append_param command -D

    config_get value "${section}" nfqueue_num 0
    procd_append_param command -q "${value}"

    procd_append_param command "${mac}"

    procd_close_instance
}
EWAKE
ok "written"

# ── 10. Enable & start services ───────────────────────────────────────────────
info "Enabling wol-trigger-nft-gen"
/etc/init.d/wol-trigger-nft-gen enable
ok "enabled"

info "Starting wol-trigger-nft-gen (generates nft file)"
/etc/init.d/wol-trigger-nft-gen start
ok "started — $(wc -l < /var/run/etherwake-nfqueue.nft) rule(s) in /var/run/etherwake-nfqueue.nft"

info "Enabling etherwake-nfqueue"
/etc/init.d/etherwake-nfqueue enable
ok "enabled"

info "Reloading rpcd (activates LuCI ACL)"
/etc/init.d/rpcd reload
ok "reloaded"

    printf "\n${GREEN}${BOLD}Done.${RESET}\n"
    printf "  LuCI: Services → Wake on LAN Targets\n"
    printf "  Add targets in LuCI, then enable the firewall include and start etherwake-nfqueue.\n"
} # end do_install

do_sysupgrade() {
    local conf="/etc/sysupgrade.conf"
    local files="
/etc/init.d/wol-trigger-nft-gen
/etc/init.d/etherwake-nfqueue
/www/luci-static/resources/view/wol-trigger.js
/usr/share/luci/menu.d/luci-app-etherwake-nfqueue.json
/usr/share/rpcd/acl.d/luci-app-etherwake-nfqueue.json
"
    info "Adding files to $conf"
    touch "$conf"
    for f in $files; do
        if grep -qxF "$f" "$conf" 2>/dev/null; then
            ok "already listed: $f"
        else
            printf '%s\n' "$f" >> "$conf"
            ok "added: $f"
        fi
    done
    printf "\n${GREEN}${BOLD}Done.${RESET}\n"
    printf "  These files will be preserved across sysupgrade.\n"
    printf "  Note: /etc/config/etherwake-nfqueue is preserved by default.\n"
}

case "$1" in
    install)    do_install ;;
    reinstall)  FORCE=1; do_install ;;
    uninstall)  do_uninstall ;;
    sysupgrade) do_sysupgrade ;;
    *)
        printf "Usage: %s <command>\n\n" "$0"
        printf "  install     Install luci-app-etherwake-nfqueue and all dependencies\n"
        printf "  reinstall   Same as install but overwrites all files and configuration\n"
        printf "  uninstall   Remove luci-app-etherwake-nfqueue (keeps UCI config)\n"
        printf "  sysupgrade  Add app files to /etc/sysupgrade.conf to survive firmware upgrades\n"
        exit 1 ;;
esac
