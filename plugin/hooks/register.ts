import { atom, read, update } from 'claude-code'
import type { EngineInterface, ModelUsage, Register, SessionUsage } from 'claude-code'

import type { CacheStats, Figures } from '../types'

// The plugin draws nothing: it only leaves each session's figures where the CacheCue menu
// bar app reads them.
const CACHE_TTL_MS = 60 * 60 * 1000
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
      isWorking = false
      await writeSnapshot($, false)
    }

    return next(e)
  })
}
