export type CacheStats = {
  /** Cache-read and total input tokens of the last main-thread turn. */
  turnRead: number
  turnTotal: number
  /** The same, summed over every turn this mod has seen in the session. */
  sumRead: number
  sumTotal: number
  /** Output tokens of the last main-thread turn. */
  turnOutput: number
  /** When a turn last wrote to the prompt cache, in epoch milliseconds. */
  writeAt: number | null
}

export type Limit = { kind: string; percentUsed: number; resetsAt?: string }

export type Figures = {
  tokens?: number
  window: number
  percent?: number
  limits: Limit[]
  usd?: number
  /**
   * When the engine handed these over fresh from an API response, in epoch
   * milliseconds; null for a reading of unknown age (taken as the mod loaded).
   */
  measuredAt: number | null
}

declare module 'claude-code' {
  interface PluginState {
    cachecue: { cache: CacheStats; figures: Figures | null; now: number }
  }
}
