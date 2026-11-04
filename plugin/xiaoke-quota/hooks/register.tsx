// Claude娘 —— 在 Claude 窗口旁的面板里陪你看剩余额度
// 额度来自会话自己的官方数据（$.session.usage() / session.measure，与状态栏同源），不需要登录或任何 key。
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Limit, Limits } from '../types'
import { buildSvg, makePages, minRemaining, pickQuote, remaining, type FrameSet, type Timeline } from './svg'

const PANE = 'xiaoke-quota'
const SIZE = 300

// 形状标签变了就换一个：旧版本存下的值不会被新代码误读
const limits = atom({ plugin: 'xiaoke-quota', key: 'limits' } as const, { items: [], at: 0 } as Limits, { shape: 'limits-1' })

type Art = { tl: Timeline; normal: FrameSet; cry: FrameSet }
let art: Art | undefined
let lastQuote: string | undefined

async function loadArt($: EngineInterface): Promise<Art> {
  if (art) return art
  const root = $.plugin.root
  const tl = JSON.parse(await $.fs.read(`${root}/assets/timeline.json`)) as Timeline
  const bytes = async (path: string) => (await $.fs.read(`${root}/assets/${path}.webp`, { as: 'bytes' })).base64
  const set = async (name: string): Promise<FrameSet> => ({
    base: await Promise.all(tl.base.map((_, k) => bytes(`${name}/b${k}`))),
    half: await bytes(`${name}/half`),
    closed: await bytes(`${name}/closed`),
  })
  art = { tl, normal: await set('normal'), cry: await set('cry') }
  return art
}

function isLimits(v: unknown): v is Limits {
  return typeof v === 'object' && v !== null && Array.isArray((v as Limits).items) && typeof (v as Limits).at === 'number'
}

async function saveLimits($: EngineInterface, items: readonly Limit[]) {
  const value: Limits = {
    items: items.map(l => ({ kind: l.kind, percentUsed: l.percentUsed, ...(l.resetsAt ? { resetsAt: l.resetsAt } : {}) })),
    at: await $.clock.now(),
  }
  await update($, limits, () => value)
  await $.store.set('limits', value)
  await writeBridge($, value)
}

// 写给桌面挂件（ClaudeNiang）读：%LOCALAPPDATA%\ClaudeNiang\bridge.json，格式与 Claude Code 状态栏的 rate_limits 相同
async function writeBridge($: EngineInterface, value: Limits) {
  try {
    const local = await $.env.get('LOCALAPPDATA')
    if (!local) return
    const rateLimits: Record<string, { used_percentage: number; resets_at?: number }> = {}
    for (const l of value.items) {
      const reset = l.resetsAt ? Math.floor(Date.parse(l.resetsAt) / 1000) : NaN
      rateLimits[l.kind] = Number.isNaN(reset) ? { used_percentage: l.percentUsed } : { used_percentage: l.percentUsed, resets_at: reset }
    }
    const body = { captured_at: Math.floor(value.at / 1000), rate_limits: rateLimits, source: 'xiaoke-quota' }
    await $.fs.write(`${local}\\ClaudeNiang\\bridge.json`, JSON.stringify(body))
  } catch {
    // 写不进去也不影响面板
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'xiaoke', description: '打开 Claude娘 面板（小克陪你看剩余额度）' })
    // 不在输入框下方的状态栏显示额度（小克在窗口右下角已经显示了）；清掉旧版本留下的那一条
    $.ui.status(undefined)
    // 先显示上次记下的额度，等这个会话第一次回复后再换成最新的
    const saved = await $.store.get('limits')
    if (isLimits(saved)) await update($, limits, () => saved)
    const usage = await $.session.usage()
    if (usage.rateLimits.length > 0) await saveLimits($, usage.rateLimits)
    // 面板不自动打开：小克主要以桌面挂件的形式贴在 Claude 窗口右下角，需要时 /xiaoke 打开面板
    return next(e)
  })

  // 额度变动一个百分点、或每轮回复结束时推送
  on('session.measure', async ($, e, next) => {
    if (e.rateLimits.length > 0) await saveLimits($, e.rateLimits)
    return next(e)
  })

  on('command.run', { command: 'xiaoke' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Claude娘' })
    return { text: 'Claude娘 面板已打开：点小克看额度，点泡泡翻页。' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const els = $.ui.resolve(e)
    const { Box, Text } = els
    const lim = await read($, limits)
    const now = await $.clock.now()

    // 终端里画不了图：给一行文字
    if (e.surface === 'terminal' || !('Svg' in els)) {
      const lines = lim.items
        .filter(l => l.kind === 'five_hour' || l.kind === 'seven_day')
        .map(l => `${l.kind === 'five_hour' ? '5小时' : '本周'}剩余 ${Math.floor(remaining(l, now))}%`)
      return (
        <Box flexDirection="column">
          <Text>{lines.length > 0 ? `小克：${lines.join(' · ')}` : '小克：发一条消息之后，我就能看到额度啦～'}</Text>
        </Box>
      )
    }

    const { Svg } = els
    const a = await loadArt($)
    const quote = pickQuote(Math.random(), Math.random(), lastQuote)
    lastQuote = quote.text
    const pages = makePages(lim, now, quote)
    const low = minRemaining(lim, now)
    const frames = low !== undefined && low < 20 ? a.cry : a.normal
    const svg = buildSvg(a.tl, frames, pages, SIZE)

    return (
      <Box flexDirection="column" alignItems="center">
        <Svg source={svg} alt={pages.map(p => (p.kind === 'quota' ? `${p.label} ${p.amount}` : p.text)).join('；')} isInteractive />
        <Text dimColor>点小克看额度 · 点泡泡翻页</Text>
      </Box>
    )
  })
}
