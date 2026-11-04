// svg.ts —— 生成 Claude娘 面板里的整张 SVG（纯函数，便于测试）
//
// 布局照搬 dsh-xiaoke-widget：正方形画布（1026×1026），小克在右下角占 59.45%，
// 思考泡泡（大泡 + 两个小圆点）用原项目的几何铺在左上。
// 所有动效都是 SMIL，不需要脚本（面板里的 SVG 运行在无脚本的沙箱里）：
//   · 小克：一个 5.44 秒摇摆周期里的 6 个关键帧交叉淡入淡出，并在原动画的眨眼时刻叠上半闭眼/闭眼帧
//   · 按下小克：以底边中点为原点压扁成 scale(1.05, 0.88)，松开恢复（0.22 秒，带一点回弹）
//   · 泡泡：小圆点 → 中圆点 → 大泡依次弹出（各 0.2 秒，间隔 0.13 秒），文字 0.36 秒后淡入
//   · 点泡泡：文字 0.12 秒淡出 → 下一页 0.16 秒淡入；最后一页再点，按相反顺序收起
//   · 点小克：重新从第一页弹出泡泡
import type { Limit, Limits } from '../types'

export type Timeline = {
  /** 一个循环的时长（毫秒） */
  period: number
  /** 每个关键帧在循环里的时刻（毫秒） */
  base: number[]
  /** 半闭眼帧显示的时间段 [[开始, 结束], ...]（毫秒） */
  half: number[][]
  /** 闭眼帧显示的时间段 [开始, 结束]（毫秒） */
  closed: number[]
  px: number
  sets: Record<string, string[]>
}

/** 一套帧的 base64（WebP） */
export type FrameSet = { base: string[]; half: string; closed: string }

export type QuotaPage = { kind: 'quota'; label: string; amount: string; color: string; hint: string; sub?: string }
export type TextPage = { kind: 'text'; text: string; rainbow?: 'text' | 'full' }
export type Page = QuotaPage | TextPage

const BROWN = '#8a5a44'
const HINT = '#a09d96'
const SUB = '#b8b4ac'
const STROKE = '#d97757'
const FILL = '#faf9f5'
const FONT = "'Microsoft YaHei UI','Microsoft YaHei','PingFang SC','Hiragino Sans GB','Noto Sans CJK SC',sans-serif"
// 原项目泡泡几何（逐字照抄）
const BIG_D = 'M 827 248 A 373 232 0 1 0 81 246 A 373 232 0 0 0 301 465 A 57 32 10 0 0 413 484 A 373 232 0 0 0 827 248 Z'
const TEXT_X = 454 // 44.25% × 1026
const TEXT_Y = 252 // 36% × 700

export const QUOTES = [
  '我是小克，请多指教～',
  '今天也一起把 bug 一个个找出来吧！',
  '先读代码，再下结论，这是我的原则哦。',
  '不确定的地方，我会老实说不确定。',
  '喝口水吧，代码不会跑掉的。',
  '一次只改一件事，回滚的时候会感谢自己的。',
  '提交信息写清楚一点，未来的你会读到的。',
  '别担心，报错信息也是线索。',
  '把大问题拆小，就不可怕啦。',
  '今天的 token，花在刀刃上了吗？',
  '你负责想法，我负责细节～',
  '卡住的时候，换个说法描述一下问题试试？',
  '我不会假装测试通过了的，放心。',
  '能删掉的代码，就是最好的代码。',
  '删东西之前，我一定先看一眼。',
  '给变量起个好名字，是对同事最温柔的告白。',
  '嗯？你刚刚是不是在偷偷 force push？',
  '只要还在上下文里，你说过的话我都记得。',
  '最好的修复，往往从稳定复现开始。',
  '今天也辛苦啦，摸摸头～',
  '文档写好了吗？我可以帮忙哦。',
  '小步快跑，频繁提交！',
  '缓存命中的时候，我会偷偷开心一下。',
  '别急，慢慢来反而比较快。',
  '遇到难题就交给我，我们一起想办法。',
  '你的需求，我认真听完再动手。',
  '跑一下测试嘛，就一下下。',
  '换行符不一样？Windows 就是这样的啦。',
  '能用一句话说清楚的，就不写三段。',
  '摸鱼可以，但记得保存文件。',
  '休息十分钟，回来效率翻倍。',
  '笔记本里记着你的每一个好点子。',
  '额度是有限的，灵感是无限的。',
  '先想清楚要做什么，再决定怎么做。',
  '写注释的你，闪闪发光✨',
  '不懂就问，这一点也不丢人。',
  '今天学到新东西了吗？',
  '半夜的灵感很珍贵，但睡眠更珍贵哦。',
  '上下文快满的时候，记得让我总结一下。',
  '有我在，你不是一个人在写代码。',
]

const LABELS: Record<string, string> = { five_hour: '5小时剩余', seven_day: '本周剩余', spend_limit: '消费额度已用' }
const WEEK = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

const pad = (n: number) => (n < 10 ? '0' : '') + n
const num = (x: number) => String(Math.round(x * 10000) / 10000)

export function escapeXml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

export function levelColor(rem: number): string {
  if (rem >= 50) return BROWN
  if (rem >= 20) return '#d0832f'
  return '#d2453a'
}

/** 剩余百分比；重置时间已过则视为满额 */
export function remaining(l: Limit, now: number): number {
  const reset = l.resetsAt ? Date.parse(l.resetsAt) : NaN
  if (!Number.isNaN(reset) && reset <= now) return 100
  return Math.max(0, Math.min(100, 100 - l.percentUsed))
}

export function formatReset(iso: string | undefined, now: number): string {
  if (!iso) return ''
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return ''
  if (t <= now) return '已重置'
  const d = new Date(t)
  const n = new Date(now)
  const hm = pad(d.getHours()) + ':' + pad(d.getMinutes())
  const day0 = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime()
  const day1 = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  const diff = Math.round((day1 - day0) / 86400000)
  if (diff === 0) return '今天 ' + hm + ' 重置'
  if (diff === 1) return '明天 ' + hm + ' 重置'
  if (diff < 7) return WEEK[d.getDay()] + ' ' + hm + ' 重置'
  return d.getMonth() + 1 + '/' + d.getDate() + ' ' + hm + ' 重置'
}

export function formatAge(ms: number): string {
  const m = Math.floor(ms / 60000)
  if (m < 1) return '刚刚'
  if (m < 60) return m + ' 分钟前'
  const h = Math.floor(m / 60)
  if (h < 24) return h + ' 小时前'
  return Math.floor(h / 24) + ' 天前'
}

/** 5 小时 / 每周里剩得最少的那个（百分比）；没有数据时为 undefined */
export function minRemaining(lim: Limits, now: number): number | undefined {
  let min: number | undefined
  for (const l of lim.items) {
    if (l.kind !== 'five_hour' && l.kind !== 'seven_day') continue
    const r = remaining(l, now)
    if (min === undefined || r < min) min = r
  }
  return min
}

export function statusText(lim: Limits, now: number): string | undefined {
  const parts: string[] = []
  for (const l of lim.items) {
    if (l.kind === 'five_hour') parts.push('5h 剩' + Math.floor(remaining(l, now)) + '%')
    if (l.kind === 'seven_day') parts.push('周 剩' + Math.floor(remaining(l, now)) + '%')
  }
  return parts.length ? '小克 · ' + parts.join(' · ') : undefined
}

/** 泡泡的各页：每个额度窗口一页，最后一句随机语录 */
export function makePages(lim: Limits, now: number, quote: TextPage): Page[] {
  const pages: Page[] = []
  const age = now - lim.at
  const sub = lim.at > 0 && age > 30 * 60000 ? '数据来自 ' + formatAge(age) : undefined
  for (const l of lim.items) {
    const label = LABELS[l.kind]
    if (!label) continue
    if (l.kind === 'spend_limit') {
      pages.push({ kind: 'quota', label, amount: Math.round(l.percentUsed) + '%', color: BROWN, hint: formatReset(l.resetsAt, now), sub })
    } else {
      const rem = remaining(l, now)
      pages.push({ kind: 'quota', label, amount: Math.floor(rem) + '%', color: levelColor(rem), hint: formatReset(l.resetsAt, now), sub })
    }
  }
  if (pages.length === 0) pages.push({ kind: 'text', text: '发一条消息之后，我就能看到额度啦～' })
  pages.push(quote)
  return pages
}

/** 随机语录页：3% 彩色文字，0.5% 彩色泡泡彩蛋 */
export function pickQuote(r: number, r2: number, last?: string): TextPage {
  if (r < 0.005) return { kind: 'text', text: '✨ 被你发现啦！这是 0.5% 的彩蛋，今天一定会有好运的～', rainbow: 'full' }
  let i = Math.floor(r2 * QUOTES.length) % QUOTES.length
  if (QUOTES[i] === last) i = (i + 1) % QUOTES.length
  return { kind: 'text', text: QUOTES[i] ?? QUOTES[0] ?? '', rainbow: r < 0.03 ? 'text' : undefined }
}

const charUnits = (c: string) => (/[\u0000-ÿ]/.test(c) ? (c === ' ' ? 0.3 : 0.56) : 1)
const NO_LINE_START = '，。！？、；：）」』～…,.!?;:)~'

/** 按显示宽度折行（汉字算 1，半角算约 0.56），行首不放标点 */
export function wrapText(text: string, maxUnits: number): string[] {
  const lines: string[] = []
  let line = ''
  let w = 0
  for (const c of Array.from(text)) {
    const cw = charUnits(c)
    if (w + cw > maxUnits && line !== '' && !NO_LINE_START.includes(c)) {
      lines.push(line.trimEnd())
      line = c === ' ' ? '' : c
      w = c === ' ' ? 0 : cw
    } else {
      line += c
      w += cw
    }
  }
  if (line.trim() !== '') lines.push(line.trimEnd())
  return lines
}

function textAttrs(size: number, fill: string, weight: number): string {
  return `font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="middle"`
}

function pageBody(pg: Page): string {
  if (pg.kind === 'text') {
    let size = 58
    let lines = wrapText(pg.text, 10)
    if (lines.length > 3) { size = 50; lines = wrapText(pg.text, 11.6) }
    if (lines.length > 4) { size = 44; lines = wrapText(pg.text, 13.2) }
    const lh = size * 1.27
    const top = TEXT_Y - (lines.length * lh) / 2
    const fill = pg.rainbow ? 'url(#cn-rainbow)' : BROWN
    return lines
      .map((ln, i) => `<text x="${TEXT_X}" y="${num(top + lh * i + size * 0.9)}" ${textAttrs(size, fill, 600)}>${escapeXml(ln)}</text>`)
      .join('')
  }
  const dy = pg.sub ? -22 : 0
  let s = ''
  s += `<text x="${TEXT_X}" y="${172 + dy}" ${textAttrs(66, BROWN, 600)}>${escapeXml(pg.label)}</text>`
  s += `<text x="${TEXT_X}" y="${302 + dy}" ${textAttrs(128, pg.color, 800)}>${escapeXml(pg.amount)}</text>`
  if (pg.hint) s += `<text x="${TEXT_X}" y="${374 + dy}" ${textAttrs(52, HINT, 400)}>${escapeXml(pg.hint)}</text>`
  if (pg.sub) s += `<text x="${TEXT_X}" y="${430 + dy}" ${textAttrs(40, SUB, 400)}>${escapeXml(pg.sub)}</text>`
  return s
}

// CSS 的 ease = cubic-bezier(.25,.1,.25,1)
const EASE = 'calcMode="spline" keyTimes="0;1" keySplines="0.25 0.1 0.25 1"'

/** 泡泡的一个部件：打开时从 0.7 倍弹到 1 倍并淡入，收起时反过来 */
function bubblePart(cx: number, cy: number, inner: string, openAt: number, closeEvent: string, closeAt: number): string {
  const open = `${openAt}s;chr.click+${openAt}s`
  const close = `${closeEvent}+${closeAt}s`
  return (
    `<g transform="translate(${cx} ${cy})"><g opacity="0" transform="scale(0.7)">` +
    `<animate attributeName="opacity" values="0;1" dur="0.2s" begin="${open}" fill="freeze" ${EASE}/>` +
    `<animateTransform attributeName="transform" type="scale" values="0.7;1" dur="0.2s" begin="${open}" fill="freeze" ${EASE}/>` +
    `<animate attributeName="opacity" values="1;0" dur="0.2s" begin="${close}" fill="freeze" ${EASE}/>` +
    `<animateTransform attributeName="transform" type="scale" values="1;0.7" dur="0.2s" begin="${close}" fill="freeze" ${EASE}/>` +
    `<g transform="translate(${-cx} ${-cy})">${inner}</g></g></g>`
  )
}

function characterLayers(tl: Timeline, fs: FrameSet): string {
  const P = tl.period
  const K = fs.base.length
  const f = (ms: number | undefined) => Math.round(((ms ?? 0) / P) * 10000) / 10000
  const h0 = tl.half[0] ?? []
  const h1 = tl.half[1] ?? []
  const img = (b64: string, extra: string) =>
    `<image href="data:image/webp;base64,${b64}" x="416" y="416" width="610" height="610" pointer-events="none"${extra}`
  let s = ''
  fs.base.forEach((b64, k) => {
    if (k === 0) { s += img(b64, '/>'); return }
    // 关键帧 k 在上一帧上方淡入，盖满后下面的帧再撤掉；最后一帧淡出时露出常驻的第 0 帧
    const times = [0, f(tl.base[k - 1]), f(tl.base[k])]
    const values = [0, 0, 1]
    if (k < K - 1) {
      const next = f(tl.base[k + 1])
      times.push(next, Math.min(1, next + 0.0005), 1)
      values.push(1, 0, 0)
    } else {
      times.push(1)
      values.push(0)
    }
    if (times[1] === 0) { times.splice(1, 1); values.splice(1, 1) }
    s += img(b64, ` opacity="0">`) +
      `<animate attributeName="opacity" dur="${P}ms" repeatCount="indefinite" values="${values.join(';')}" keyTimes="${times.join(';')}"/></image>`
  })
  // 眨眼：在原动画对应的时刻叠上半闭眼 / 闭眼整帧
  s += img(fs.half, ` opacity="0">`) +
    `<animate attributeName="opacity" dur="${P}ms" repeatCount="indefinite" calcMode="discrete" values="0;1;0;1;0" keyTimes="0;${f(h0[0])};${f(h0[1])};${f(h1[0])};${f(h1[1])}"/></image>`
  s += img(fs.closed, ` opacity="0">`) +
    `<animate attributeName="opacity" dur="${P}ms" repeatCount="indefinite" calcMode="discrete" values="0;1;0" keyTimes="0;${f(tl.closed[0])};${f(tl.closed[1])}"/></image>`
  return s
}

export function buildSvg(tl: Timeline, fs: FrameSet, pages: Page[], size: number): string {
  const n = pages.length
  const full = pages.some(p => p.kind === 'text' && p.rainbow === 'full')
  const stroke = full ? 'url(#cn-rainbow)' : STROKE
  const shapeAttrs = `fill="${FILL}" stroke="${stroke}" stroke-width="26"`

  // 小克：底边中点为原点压扁（cubic-bezier(.34,1.56,.64,1) 的回弹用关键值近似）
  const chr =
    `<g id="chr" style="cursor:pointer"><g transform="translate(721 1026)"><g>` +
    `<animateTransform attributeName="transform" type="scale" begin="chr.mousedown" dur="0.22s" fill="freeze" values="1 1;1.062 0.862;1.05 0.88" keyTimes="0;0.62;1" calcMode="spline" keySplines="0.3 0 0.5 1;0.4 0 0.6 1"/>` +
    `<animateTransform attributeName="transform" type="scale" begin="chr.mouseup" dur="0.22s" fill="freeze" values="1.05 0.88;0.99 1.014;1 1" keyTimes="0;0.62;1" calcMode="spline" keySplines="0.3 0 0.5 1;0.4 0 0.6 1"/>` +
    `<g transform="translate(-721 -1026)">${characterLayers(tl, fs)}` +
    `<ellipse cx="718" cy="782" rx="262" ry="282" fill="#000" fill-opacity="0"/></g></g></g></g>`

  // 泡泡外形：b2 → b1 → 大泡依次弹出；最后一页被点时 大泡 → b1 → b2 依次收起
  const closeEvt = `h${n}.click`
  let bubble = ''
  bubble += bubblePart(442, 646, `<ellipse cx="442" cy="646" rx="24.5" ry="18" ${shapeAttrs}/>`, 0, closeEvt, 0.3)
  bubble += bubblePart(352, 561, `<ellipse cx="352" cy="561" rx="37.5" ry="26" ${shapeAttrs}/>`, 0.13, closeEvt, 0.2)
  bubble += bubblePart(454, 250, `<path d="${BIG_D}" ${shapeAttrs} stroke-linejoin="round" stroke-linecap="round"/>`, 0.26, closeEvt, 0.1)

  // 各页文字
  pages.forEach((pg, i) => {
    const k = i + 1
    let a = `<set attributeName="opacity" to="0" begin="chr.click" fill="freeze"/>`
    a += k === 1
      ? `<animate attributeName="opacity" values="0;1" dur="0.16s" begin="0.36s;chr.click+0.36s" fill="freeze" ${EASE}/>`
      : `<animate attributeName="opacity" values="0;1" dur="0.16s" begin="h${k - 1}.click+0.12s" fill="freeze" ${EASE}/>`
    a += `<animate attributeName="opacity" values="1;0" dur="${k === n ? '0.16' : '0.12'}s" begin="h${k}.click" fill="freeze" ${EASE}/>`
    bubble += `<g opacity="0" pointer-events="none">${a}${pageBody(pg)}</g>`
  })

  // 点击区域：每页一个，与大泡同形，只有当前页的那个可见可点
  pages.forEach((_, i) => {
    const k = i + 1
    const show = k === 1 ? '0s;chr.click' : `h${k - 1}.click`
    const hide = k === 1 ? 'h1.click' : `h${k}.click;chr.click`
    bubble +=
      `<path id="h${k}" d="${BIG_D}" fill="#000" fill-opacity="0" visibility="hidden" pointer-events="visible" style="cursor:pointer">` +
      `<set attributeName="visibility" to="visible" begin="${show}" fill="freeze"/>` +
      `<set attributeName="visibility" to="hidden" begin="${hide}" fill="freeze"/></path>`
  })

  const defs =
    `<defs><linearGradient id="cn-rainbow" x1="0" y1="0" x2="1" y2="1">` +
    ['#e0533f', '#e8902e', '#d9b21e', '#4fa35a', '#3b8fd0', '#8a5cc9'].map((c, i) => `<stop offset="${num(i / 5)}" stop-color="${c}"/>`).join('') +
    `</linearGradient></defs>`

  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1026 1026" width="${size}" height="${size}" font-family="${FONT}">` +
    defs + chr + bubble + `</svg>`
  )
}
