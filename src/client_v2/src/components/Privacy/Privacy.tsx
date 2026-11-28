import { createSignal, For } from 'solid-js';
import cn from 'clsx';

import { SettingRow } from 'panel/common/ui/SettingRow';
import theme from 'panel/lib/theme';

import s from './Privacy.module.pcss';

/**
 * 隐私页。
 *
 * 界面结构与原版内嵌页一致：h1 标题 + 8 个 SettingRow（switch / align top /
 * title + description）+ 4 个外链检测 + 尾部说明。
 *
 * 数据面刻意与原版不同，而这一处不同就是本页存在的理由：
 *
 * 原版把初值写成 `_({dns:!0,vpn:!0,ip:!0,...})`（全真），再把同步 XHR 放进
 * `A(()=>{...})`（挂载后的 effect）。首帧按全真渲染成 8 个绿，effect 跑完才
 * 被 conf 真值覆盖 —— conf 里只要有 0 项，就必然「先绿后灰」跳一下；dns/vpn/ip
 * 恒为 1 所以看不出跳。
 *
 * 这里把同步 XHR 挪到 `createSignal` 的初值位置：signal 一出生就是真值，
 * 首帧即 conf，没有第二帧可跳。点开关时只改本地 signal + 发一次 POST，POST
 * 回来不回写、也没有任何 effect 重新 GET，一次点击就是一次翻转。
 *
 * 键集固定 8 个，sb / par 两个废键不在前端出现。
 */

const ENDPOINT = 'http://127.0.0.1:6081/cgi-bin/privacy';

const KEYS = ['dns', 'vpn', 'ip', 'ntp', 'dhcp', 'smb', 'tcp', 'snmp'] as const;

type PrivacyKey = (typeof KEYS)[number];
type PrivacyState = Record<PrivacyKey, boolean>;

type Item = { key: PrivacyKey; title: string; desc: string };

const ITEMS: Item[] = [
    {
        key: 'dns',
        title: '防止 DNS 泄露',
        desc: '丢弃 mDNS / SSDP / NetBIOS 探针，全部解析强制走 AGH 加密上游，检测网站看不到运营商 DNS。',
    },
    {
        key: 'vpn',
        title: '防止 VPN 泄露',
        desc: '阻断 STUN / TURN 与 Teredo 隧道协商，WebRTC 暴露不出真实出口；VPN 断开也不会回落到本地网络。',
    },
    {
        key: 'ip',
        title: '防止 IP 泄露',
        desc: '屏蔽 WebRTC ICE 收集所需的 STUN 端口，网站拿不到局域网 IP 与公网映射地址。',
    },
    {
        key: 'ntp',
        title: '防止 NTP 时钟泄露',
        desc: '丢弃出网 NTP 对时请求（UDP 123）。时钟指纹可跨网络关联同一设备；本机时间由系统维护不受影响。',
    },
    {
        key: 'dhcp',
        title: '防止 DHCP 探测泄露',
        desc: '丢弃出网 DHCP 广播（UDP 67）。防恶意热点通过 DHCP 指纹识别设备型号与系统。',
    },
    {
        key: 'smb',
        title: '防止局域网探测泄露',
        desc: '丢弃 NetBIOS / SMB 出网流量（137/139/445）。防内网扫描器读取设备名与共享目录。',
    },
    {
        key: 'tcp',
        title: '防止明文协议泄露',
        desc: '丢弃 Telnet / SMTP / POP3 / IMAP 明文端口出网（23/25/110/143）。防 App 明文回传数据。',
    },
    {
        key: 'snmp',
        title: '防止 SNMP 信息泄露',
        desc: '丢弃 SNMP 查询与陷阱（161/162）。防设备信息（系统版本、接口列表）被读取。',
    },
];

const CHECKS = [
    { label: 'DNS 泄露检测', url: 'https://browserleaks.com/dns' },
    { label: 'WebRTC 泄露检测', url: 'https://browserleaks.com/webrtc' },
    { label: 'IP 与位置检测', url: 'https://ipleak.net/' },
    { label: '综合检测', url: 'https://browserleaks.com/ip' },
];

/** 读不到 conf 时全部按开启兜底，页面不会渲染成一片灰。 */
const allOn = (): PrivacyState =>
    KEYS.reduce((acc, k) => {
        acc[k] = true;

        return acc;
    }, {} as PrivacyState);

/**
 * 同步读取 conf，在组件构造期调用一次。
 *
 * 走 127.0.0.1，毫秒级；代价换来首帧即真值。
 */
const readState = (): PrivacyState => {
    const state = allOn();

    try {
        const xhr = new XMLHttpRequest();

        xhr.open('GET', ENDPOINT, false);
        xhr.send();

        if (xhr.status !== 200) {
            return state;
        }

        const data = JSON.parse(xhr.responseText || '{}') as Record<string, unknown>;

        for (const k of KEYS) {
            const v = data[k];

            if (typeof v === 'boolean') {
                state[k] = v;
            } else if (typeof v === 'number') {
                state[k] = v !== 0;
            } else if (typeof v === 'string') {
                state[k] = v !== '0' && v !== '' && v !== 'false';
            }
        }
    } catch {
        // 读不到就维持全开。
    }

    return state;
};

/** 整表 POST。异步发送，回调不回写、不重读。 */
const pushState = (state: PrivacyState): void => {
    try {
        const body = KEYS.map((k) => `${k}=${state[k] ? 1 : 0}`).join('&');
        const xhr = new XMLHttpRequest();

        xhr.open('POST', ENDPOINT, true);
        xhr.setRequestHeader('Content-Type', 'text/plain');
        xhr.send(body);
    } catch {
        // 网络层失败不影响本地视觉状态。
    }
};

export const Privacy = () => {
    // 构造期同步求值：初值即真值，没有第二帧可跳。
    const [state, setState] = createSignal<PrivacyState>(readState());

    const toggle = (key: PrivacyKey, checked: boolean) => {
        const next = { ...state(), [key]: checked };

        setState(next);
        pushState(next);
    };

    return (
        <div class={cn(theme.layout.container, s.container)}>
            <div class={cn(theme.layout.containerIn, theme.layout.containerIn_one_col)}>
                <h1 class={cn(theme.layout.title, theme.title.h4, theme.title.h3_tablet, s.title)}>
                    隐私
                </h1>

                <div id="privacy-leaks">
                    <For each={ITEMS}>
                        {(item) => (
                            <SettingRow
                                variant="switch"
                                id={`privacy_${item.key}`}
                                title={item.title}
                                description={item.desc}
                                align="top"
                                checked={state()[item.key]}
                                onChange={(checked: boolean) => toggle(item.key, checked)}
                            />
                        )}
                    </For>
                </div>

                <div class={s.checks} id="privacy-checks">
                    <div class={s.checksTitle}>泄露检测</div>
                    <div class={s.links}>
                        <For each={CHECKS}>
                            {(c) => (
                                <a
                                    class={s.link}
                                    href={c.url}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                >
                                    {c.label}
                                </a>
                            )}
                        </For>
                    </div>
                    <p class={s.note}>
                        网络层开关（DNS/VPN/IP/NTP/DHCP/局域网/明文协议/SNMP）即时生效。
                    </p>
                </div>
            </div>
        </div>
    );
};
