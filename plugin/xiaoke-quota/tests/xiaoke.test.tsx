import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PANE = {
  plugin: 'xiaoke-quota',
  component: 'Pane',
  requestId: 'xiaoke-quota',
  props: {
    title: 'Claude娘',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

const TIMELINE = JSON.stringify({ period: 5440, base: [0, 880, 1840, 2720, 3600, 4560], half: [[1240, 1320], [1440, 1480]], closed: [1320, 1440], px: 220, sets: {} })
const NOW = Date.parse('2026-11-04T04:00:00Z')
const HOUR = 3600e3
const iso = (ms: number) => new Date(ms).toISOString()

// 测试里没有文件系统和真实会话：这些 hook 替引擎回答插件的调用
const writes: { path: string; text: string }[] = []

function engine(on: On, rateLimits: unknown[], stored?: unknown) {
  writes.length = 0
  mock.clock(on, { now: NOW })
  mock.store(on, stored === undefined ? {} : { limits: stored })
  mock.env(on, { LOCALAPPDATA: 'C:\\Users\\me\\AppData\\Local' })
  on('fs.write', (_, e) => {
    const w = e as unknown as { path: string; text: string }
    writes.push({ path: w.path, text: w.text })
    return { value: undefined }
  })
  on('command.register', () => ({ value: { command: 'xiaoke' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('session.usage', () => ({ value: { startedAt: 0, context: {}, rateLimits, cost: {} } }))
  on('fs.read', (_, e) => {
    const path = String((e as { path: string }).path)
    return path.endsWith('.json') ? { value: TIMELINE } : { value: { base64: 'UklGRg==' } }
  })
}

async function paneSource($: Parameters<Parameters<typeof test>[1]>[0], surface: 'desktop' | 'terminal' = 'desktop') {
  const ui = await $.ui.mount({ ...PANE, surface })
  const svg = await ui.find({ type: 'Svg' })
  const text = await ui.find({ type: 'Text', text: /小克/ })
  await ui.unmount()
  return { source: String(svg?.props.source ?? ''), text: text?.text }
}

test('面板画出小克和各页额度', async ($, on) => {
  engine(on, [
    { kind: 'five_hour', percentUsed: 23.5, resetsAt: iso(NOW + 2 * HOUR) },
    { kind: 'seven_day', percentUsed: 61, resetsAt: iso(NOW + 50 * HOUR) },
  ])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const { source } = await paneSource($)
  expect(source.includes('5小时剩余')).toBe(true)
  expect(source.includes('>76%<')).toBe(true)
  expect(source.includes('本周剩余')).toBe(true)
  expect(source.includes('>39%<')).toBe(true)
  expect(source.includes('今天 15:00 重置')).toBe(true) // 本地时区 UTC+9
  expect(source.includes('id="h3"')).toBe(true) // 两页额度 + 一句语录
  expect(source.length < 131072).toBe(true)
})

test('额度推送后面板更新，低于 20% 时数字变红', async ($, on) => {
  engine(on, [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.session.measure({ context: {}, rateLimits: [{ kind: 'five_hour', percentUsed: 91, resetsAt: iso(NOW + HOUR) }], changed: ['rateLimits'] } as never)

  const { source } = await paneSource($)
  expect(source.includes('>9%<')).toBe(true)
  expect(source.includes('#d2453a')).toBe(true)
})

test('新会话先显示上次记下的额度，并标出数据时间', async ($, on) => {
  engine(on, [], { items: [{ kind: 'five_hour', percentUsed: 50, resetsAt: iso(NOW + 3 * HOUR) }], at: NOW - 2 * HOUR })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const { source } = await paneSource($)
  expect(source.includes('>50%<')).toBe(true)
  expect(source.includes('数据来自 2 小时前')).toBe(true)
})

test('拿到额度后写给桌面挂件读', async ($, on) => {
  engine(on, [{ kind: 'five_hour', percentUsed: 62, resetsAt: iso(NOW + HOUR) }, { kind: 'seven_day', percentUsed: 14 }])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const w = writes.find(x => x.path.endsWith('bridge.json'))
  expect(w?.path).toBe('C:\\Users\\me\\AppData\\Local\\ClaudeNiang\\bridge.json')
  const body = JSON.parse(w?.text ?? '{}') as { captured_at: number; rate_limits: Record<string, { used_percentage: number; resets_at?: number }> }
  expect(body.captured_at).toBe(Math.floor(NOW / 1000))
  expect(body.rate_limits.five_hour?.used_percentage).toBe(62)
  expect(body.rate_limits.five_hour?.resets_at).toBe(Math.floor((NOW + HOUR) / 1000))
  expect(body.rate_limits.seven_day?.used_percentage).toBe(14)
})

test('还没有数据时给提示', async ($, on) => {
  engine(on, [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const { source } = await paneSource($)
  expect(source.includes('发一条消息之后')).toBe(true)
})

test('终端里给一行文字', async ($, on) => {
  engine(on, [{ kind: 'five_hour', percentUsed: 40 }])
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const { text } = await paneSource($, 'terminal')
  expect(text).toBe('小克：5小时剩余 60%')
})
