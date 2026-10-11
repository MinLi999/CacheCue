import { atom, read, update } from 'claude-code'
import type { EngineInterface, ModelUsage, Register, SessionUsage } from 'claude-code'

import type { CacheStats, Figures, Limit } from '../types'

const CACHE_TTL_MS = 60 * 60 * 1000
const TICK_MS = 5000
const BAR_CELLS = 8
// Where the menu bar app looks; the terminal's status line command writes here too.
const SNAPSHOT_DIR = 'Library/Caches/CacheCue'

const NO_STATS: CacheStats = {
  turnRead: 0,
  turnTotal: 0,
  sumRead: 0,
  sumTotal: 0,
  turnOutput: 0,
  writeAt: null,
}

const cache = atom({ plugin: 'cachecue', key: 'cache' } as const, NO_STATS)
const figures = atom({ plugin: 'cachecue', key: 'figures' } as const, null)
const now = atom({ plugin: 'cachecue', key: 'now' } as const, 0)

// Theme keys, so the ramp follows the person's theme (daltonized included).
type Tone = 'success' | 'warning' | 'error'

export const tone = (percent: number, warn: number, crit: number): Tone =>
  percent >= crit ? 'error' : percent >= warn ? 'warning' : 'success'

export const hitTone = (percent: number): Tone =>
  percent < 50 ? 'error' : percent < 80 ? 'warning' : 'success'

export const formatTokens = (count: number): string => {
  if (count >= 1_000_000) {
    return `${(count / 1_000_000).toFixed(1)}M`
  }
  if (count >= 1_000) {
    return `${(count / 1_000).toFixed(1)}k`
  }

  return String(Math.round(count))
}

export const formatReset = (ms: number): string => {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) {
    return `${days}d${hours}h`
  }
  if (hours > 0) {
    return `${hours}h${String(minutes).padStart(2, '0')}m`
  }

  return `${minutes}m`
}

export const formatCountdown = (ms: number): string => {
  const seconds = Math.floor(ms / 1000)
  const pad = (value: number) => String(value).padStart(2, '0')

  return `${pad(Math.floor(seconds / 60))}:${pad(seconds % 60)}`
}

export const barCells = (percent: number): number => {
  const filled = Math.min(BAR_CELLS, Math.max(0, Math.round((percent * BAR_CELLS) / 100)))

  return percent > 0 && filled === 0 ? 1 : filled
}

// When to /compact, in a few words: the same rules as the menu bar app's advice card.
// Thresholds are rules of thumb, not figures from Anthropic.
const SMALL_CONTEXT = 50_000
const LARGE_CONTEXT = 100_000
const NEAR_FULL_PERCENT = 80
const EXPIRY_WINDOW_MS = 10 * 60 * 1000

export type CompactCue = { text: string; tone: Tone }

export const compactCue = (
  tokens: number,
  percent: number | undefined,
  // Milliseconds left on the cache; null while nothing is known of it.
  left: number | null,
  isWorking: boolean,
): CompactCue | null => {
  // Nothing can be compacted until the turn ends.
  if (isWorking) {
    return null
  }
  // Auto-compact is about to choose the moment itself.
  if (percent !== undefined && percent >= NEAR_FULL_PERCENT) {
    return { text: 'compact now', tone: 'error' }
  }
  // Too little context for compacting to pay for itself.
  if (tokens < SMALL_CONTEXT) {
    return null
  }
  // Expired: the next message reprocesses everything either way.
  if (left !== null && left <= 0) {
    return { text: 'compact or clear', tone: 'error' }
  }
  // About to expire: compacting while warm costs a fraction of doing it after.
  if (left !== null && left <= EXPIRY_WINDOW_MS) {
    return { text: 'compact now', tone: left <= 120_000 ? 'error' : 'warning' }
  }

  return tokens >= LARGE_CONTEXT ? { text: 'compact at next break', tone: 'warning' } : null
}

const hitPercent = (readTokens: number, total: number): number | null =>
  total > 0 ? Math.round((readTokens * 100) / total) : null

const inputTokens = (usage: ModelUsage): number =>
  usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens

const toFigures = (
  usage: Pick<SessionUsage, 'context' | 'rateLimits' | 'cost'>,
  measuredAt: number | null,
): Figures => ({
  measuredAt,
  tokens: usage.context.tokens,
  window: usage.context.window,
  percent: usage.context.percent,
  limits: usage.rateLimits.map(limit => ({
    kind: limit.kind,
    percentUsed: limit.percentUsed,
    resetsAt: limit.resetsAt,
  })),
  usd: usage.cost?.usd,
})

const toEpochSeconds = (iso: string | undefined): number | null => {
  const ms = iso === undefined ? Number.NaN : Date.parse(iso)

  return Number.isNaN(ms) ? null : Math.round(ms / 1000)
}

// Leaves this session's figures for the menu bar app. A turn in flight is
// `active`: its requests keep the cache in use until it ends. Written only when the
// session did something, so `updated_at` says which session is the live one.
async function writeSnapshot($: EngineInterface, isActive: boolean): Promise<void> {
  try {
    const surface = await $.session.surface()
    const home = await $.env.get('HOME')
    // In a terminal the status line command writes this session's file.
    if (surface === 'terminal' || home === undefined) {
      return
    }
    const id = await $.session.id()
    const stats = await read($, cache)
    const held = await read($, figures)
    const limits: Record<string, { used: number; resets_at: number | null }> = {}
    for (const limit of held?.limits ?? []) {
      if (limit.kind === 'five_hour' || limit.kind === 'seven_day') {
        limits[limit.kind] = { used: limit.percentUsed, resets_at: toEpochSeconds(limit.resetsAt) }
      }
    }
    const snapshot = {
      v: 1,
      source: surface ?? 'desktop',
      session_id: id,
      // The project root, which names the session; a shell `cd` mid-session moves cwd, not this.
      cwd: await $.session.root(),
      cache: {
        turn_hit: hitPercent(stats.turnRead, stats.turnTotal),
        avg_hit: hitPercent(stats.sumRead, stats.sumTotal),
        expires_at:
          stats.writeAt === null ? null : Math.round((stats.writeAt + CACHE_TTL_MS) / 1000),
        active: isActive,
      },
      limits,
      // The limits are the account's and every session holds its own last reading:
      // this is how the app tells the freshest one.
      limits_at: held?.measuredAt == null ? null : Math.round(held.measuredAt / 1000),
      context: {
        tokens: held?.tokens ?? 0,
        output: stats.turnOutput,
        window: held?.window ?? 0,
        percent: held?.percent ?? null,
      },
      cost_usd: held?.usd ?? null,
      updated_at: Math.round((await $.clock.now()) / 1000),
    }
    await $.fs.write(`${home}/${SNAPSHOT_DIR}/${id}.json`, JSON.stringify(snapshot))
  } catch (error) {
    // The menu bar going stale must not cost the session its hook.
    $.ui.log(`cachecue: snapshot not written: ${String(error)}`, { to: 'debug' })
  }
}

async function tick($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  await update($, now, () => at)
}

export const register: Register = on => {
  // Main-thread turn in flight; a reload starts it over, and reloads fall between turns.
  let isWorking = false

  on('session.start', async ($, e, next) => {
    // What the engine holds as the mod loads is its last reading, of unknown age:
    // keep the time of one the mod itself saw arrive, when it is the same reading.
    const loaded = toFigures(await $.session.usage(), null)
    await update($, figures, held =>
      held !== null && JSON.stringify(held.limits) === JSON.stringify(loaded.limits)
        ? { ...loaded, measuredAt: held.measuredAt }
        : loaded,
    )
    await tick($)
    // Countdowns move without any event; the timer ends with the module.
    $.clock.every(TICK_MS, () => void tick($))

    // Loaded mid-session, the last turn's hit rate is still on the live window.
    const stats = await read($, cache)
    if (stats.turnTotal === 0) {
      const { context } = await $.session.usage({ breakdown: 'summary' })
      const last = context.breakdown?.apiUsage
      if (last) {
        await update($, cache, held => ({
          ...held,
          turnRead: last.cache_read_input_tokens,
          turnTotal: inputTokens(last),
          turnOutput: last.output_tokens,
        }))
      }
    }

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    const at = await $.clock.now()
    await update($, figures, () => toFigures(e, at))
    await writeSnapshot($, isWorking)

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    isWorking = true
    await writeSnapshot($, true)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const usage = e.usage
    if (e.agentId === undefined && usage !== undefined) {
      const at = await $.clock.now()
      const total = inputTokens(usage)
      await update($, cache, held => ({
        turnRead: usage.cache_read_input_tokens,
        turnTotal: total,
        sumRead: held.sumRead + usage.cache_read_input_tokens,
        sumTotal: held.sumTotal + total,
        turnOutput: usage.output_tokens,
        writeAt: usage.cache_creation_input_tokens > 0 ? at : held.writeAt,
      }))
      await update($, now, () => at)
      isWorking = false
      await writeSnapshot($, false)
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // The terminal has the status line for this; drawing here too would say it twice.
    if (e.props.hasSurvey || e.surface === 'terminal') {
      return next(e)
    }

    const { Box, Text } = $.ui.resolve(e)
    const stats = await read($, cache)
    const held = await read($, figures)
    const at = await read($, now)

    const turnHit = hitPercent(stats.turnRead, stats.turnTotal)
    const averageHit = hitPercent(stats.sumRead, stats.sumTotal)
    const left = stats.writeAt === null ? null : stats.writeAt + CACHE_TTL_MS - at

    const expiry = () => {
      // A running turn keeps the cache in use; the count restarts when it ends.
      if (e.props.isWorking) {
        return <Text dimColor>◷active</Text>
      }
      if (left === null) {
        return <Text dimColor>◷--:--</Text>
      }
      if (left <= 0) {
        return <Text color="error">◷expired</Text>
      }
      const color = left <= 120_000 ? 'error' : left <= 600_000 ? 'warning' : 'text'

      return <Text color={color}>◷{formatCountdown(left)}</Text>
    }

    const limit = (label: string, kind: string) => {
      const found: Limit | undefined = held?.limits.find(one => one.kind === kind)
      if (found === undefined) {
        return <Text dimColor>{label} --</Text>
      }
      const filled = barCells(found.percentUsed)
      const color = tone(found.percentUsed, 70, 90)
      const resetsAt = found.resetsAt === undefined ? Number.NaN : Date.parse(found.resetsAt)

      return (
        <Box flexDirection="row">
          <Text dimColor>{label} </Text>
          <Text color={color}>{'▰'.repeat(filled)}</Text>
          <Text dimColor>{'▱'.repeat(BAR_CELLS - filled)}</Text>
          <Text color={color}> {Math.round(found.percentUsed)}%</Text>
          {Number.isNaN(resetsAt) ? null : <Text dimColor> ↻{formatReset(resetsAt - at)}</Text>}
        </Box>
      )
    }

    const separator = <Text dimColor> | </Text>
    const cue = compactCue(held?.tokens ?? 0, held?.percent, left, e.props.isWorking)
    const contextColor = held?.percent === undefined ? 'text' : tone(held.percent, 60, 85)

    return (
      <Box flexDirection="row" flexWrap="wrap">
        <Text dimColor>cache </Text>
        {turnHit === null ? (
          <Text dimColor>--</Text>
        ) : (
          <Text bold color={hitTone(turnHit)}>
            {turnHit}%
          </Text>
        )}
        {averageHit === null ? null : <Text dimColor> avg </Text>}
        {averageHit === null ? null : <Text color={hitTone(averageHit)}>{averageHit}%</Text>}
        <Text> </Text>
        {expiry()}
        {separator}
        {limit('5h', 'five_hour')}
        {separator}
        {limit('7d', 'seven_day')}
        {separator}
        <Text color={contextColor}>↑{formatTokens(held?.tokens ?? 0)}</Text>
        <Text dimColor> ↓{formatTokens(stats.turnOutput)}</Text>
        <Text color="suggestion"> ◆{formatTokens(held?.window ?? 0)}</Text>
        {separator}
        <Text>${(held?.usd ?? 0).toFixed(2)}</Text>
        {cue === null ? null : separator}
        {cue === null ? null : <Text color={cue.tone}>⇲ {cue.text}</Text>}
      </Box>
    )
  })
}
