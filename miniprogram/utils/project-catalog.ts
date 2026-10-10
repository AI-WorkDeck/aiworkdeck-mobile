// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import type { RelayProject } from './api'

export interface ProjectLocation {
  kind: 'desktop' | 'cloud'
  deviceId: string
  deviceName?: string | null
  key: string
  online?: boolean
  archiveOnly?: boolean
}
export interface CatalogProject {
  projectUid: string
  name: string
  locations: ProjectLocation[]
}
export function fromCatalog(project: CatalogProject): RelayProject {
  const location = project.locations.find(p => p.kind === 'cloud' && !p.archiveOnly)
    ?? project.locations.find(p => p.kind === 'desktop' && p.online)
    ?? project.locations.find(p => p.kind === 'desktop') ?? project.locations[0]
  if (!location) throw new Error('Project has no location')
  return { deviceId: location.deviceId, deviceName: location.deviceName ?? null,
    key: location.key, name: project.name, projectUid: project.projectUid, locations: project.locations }
}
export function sameProject(a: RelayProject, b: RelayProject): boolean {
  if (a.projectUid && b.projectUid) return a.projectUid === b.projectUid
  const aliases = (p: RelayProject) => [p, ...(p.locations ?? [])].map(l => `${l.deviceId}:${l.key}`)
  return aliases(a).some(id => aliases(b).includes(id))
}
