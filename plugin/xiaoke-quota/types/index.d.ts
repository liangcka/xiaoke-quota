/** 一个额度窗口：five_hour / seven_day / spend_limit，与 $.session.usage().rateLimits 同形 */
export type Limit = { kind: string; percentUsed: number; resetsAt?: string }

/** 最近一次读到的额度，以及读到的时间（毫秒）；at 为 0 表示还没有数据 */
export type Limits = { items: Limit[]; at: number }

declare module 'claude-code' {
  interface PluginState {
    'xiaoke-quota': { limits: Shaped<Limits> }
  }
}
