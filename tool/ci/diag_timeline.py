# DIAG ONLY (diag/gradle-timing 分支)：解析 init script 打点，输出 Gradle 任务时间线。
# 用法：python3 tool/ci/diag_timeline.py <build.log> [<build2.log> ...]
import re
import sys

SESSION_GAP_MS = 20000  # 合并区间之间超过 20 s 视为「另一次 Gradle 构建」

r_init = re.compile(r'\[\[DIAG\]\] init-loaded @(\d+)')
r_ready = re.compile(r'\[\[DIAG\]\] graph-ready tasks=(\d+) @(\d+)')
r_start = re.compile(r'\[\[DIAG-START\]\] (\S+) @(\d+)')
r_end = re.compile(r'\[\[DIAG-END\]\] (\S+) @(\d+) (\S+)')


def parse(path):
    try:
        raw = open(path, encoding='utf-8', errors='replace').read()
    except FileNotFoundError:
        print(f'no log at {path}')
        return None
    inits, readies, recs = [], [], []
    pending = {}
    for ln in raw.replace('\r', '').splitlines():
        m = r_init.search(ln)
        if m:
            inits.append(int(m.group(1)))
            continue
        m = r_ready.search(ln)
        if m:
            readies.append((int(m.group(1)), int(m.group(2))))
            continue
        m = r_start.search(ln)
        if m:
            pending.setdefault(m.group(1), []).append(int(m.group(2)))
            continue
        m = r_end.search(ln)
        if m:
            name, end, status = m.group(1), int(m.group(2)), m.group(3)
            stack = pending.get(name) or []
            start = stack.pop() if stack else end
            recs.append((start, end, status, name))
    return {'inits': inits, 'readies': readies, 'recs': recs, 'path': path}


def sessions(recs):
    out, cur = [], []
    cur_end = None
    for rec in sorted(recs):
        if cur and rec[0] - cur_end > SESSION_GAP_MS:
            out.append(cur)
            cur = []
        cur.append(rec)
        cur_end = max(cur_end or 0, rec[1]) if cur else rec[1]
    if cur:
        out.append(cur)
    return out


def report(data):
    recs = data['recs']
    print(f'######## {data["path"]}')
    if not recs:
        print('no [[DIAG-*]] markers found —— init script 没生效，检查 ~/.gradle/init.d')
        return
    t_init = min(data['inits']) if data['inits'] else min(r[0] for r in recs)
    t_last = max(r[1] for r in recs)

    print('=== 相位 ===')
    for n, t in data['readies']:
        print(f'graph-ready: tasks={n:<5} @+{(t - t_init) / 1000:7.1f}s   (init → 配置结束 {(t - t_init) / 1000:.1f}s)')
    print(f'首个任务开始 → 末个任务结束: {(t_last - min(r[0] for r in recs)) / 1000:8.1f}s / {len(recs)} 个任务')
    print(f'init → 末个任务结束        : {(t_last - t_init) / 1000:8.1f}s')
    print()

    sess = sessions(recs)
    for i, s in enumerate(sess, 1):
        wall = (max(r[1] for r in s) - min(r[0] for r in s)) / 1000
        print(f'=== 构建段 {i}: 墙钟 {wall:.1f}s，任务 {len(s)} 个 ===')
        print(f'{"秒":>9}  {"状态":<11} {"开始@+s":>9}  任务')
        for start, end, status, name in sorted(s, key=lambda r: r[1] - r[0], reverse=True)[:25]:
            print(f'{(end - start) / 1000:9.1f}  {status:<11} {(start - t_init) / 1000:9.1f}  {name}')
        agg = {}
        for start, end, status, name in s:
            proj = name.rsplit(':', 1)[0] if ':' in name else name
            agg[proj] = agg.get(proj, 0) + (end - start)
        print('  -- 按项目汇总（并行时总和 > 墙钟）--')
        for proj, ms in sorted(agg.items(), key=lambda kv: kv[1], reverse=True)[:10]:
            print(f'{ms / 1000:9.1f}s  {proj}')
        st_agg = {}
        for start, end, status, name in s:
            st_agg[status] = st_agg.get(status, 0) + 1
        print('  -- 状态分布 --')
        for status, count in sorted(st_agg.items(), key=lambda kv: kv[1], reverse=True):
            print(f'{count:5d}  {status}')
        merged = []
        for start, end in sorted((r[0], r[1]) for r in s):
            if merged and start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        gaps = [(merged[j + 1][0] - merged[j][1], merged[j][1]) for j in range(len(merged) - 1)]
        gaps = [g for g in gaps if g[0] > 500]
        if gaps:
            print('  -- 空档 top 8（无任务在跑的墙钟）--')
            for gap, at in sorted(gaps, reverse=True)[:8]:
                print(f'{gap / 1000:8.1f}s  @+{(at - t_init) / 1000:7.1f}s')
        print()

    print('=== 事件序列（相对时间，秒；最多 300 行）===')
    events = []
    for start, end, status, name in recs:
        events.append((start, 'START', name, status))
        events.append((end, 'END  ', name, status))
    for ts, kind, name, status in sorted(events)[:300]:
        print(f'+{(ts - t_init) / 1000:8.1f}  {kind}  {name}  {status}')


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: diag_timeline.py <build.log> [...]')
        return 2
    for path in sys.argv[1:]:
        data = parse(path)
        if data:
            report(data)
            print()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
