/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** PostHog project API key（公开 key，可打包进前端）。未配置则禁用埋点。 */
  readonly VITE_PUBLIC_POSTHOG_KEY?: string
  /** PostHog 实例地址，US: https://us.i.posthog.com，EU: https://eu.i.posthog.com */
  readonly VITE_PUBLIC_POSTHOG_HOST?: string
  /** Sentry DSN（公开客户端 DSN）。未配置则崩溃上报 no-op。 */
  readonly VITE_PUBLIC_SENTRY_DSN?: string
  /** 打包时注入的应用版本，给 Sentry release 用。 */
  readonly VITE_APP_VERSION?: string
  /** Dev-only flag overrides, `name=value` comma separated. Ignored in production builds. */
  readonly VITE_FLAGS?: string
  /**
   * 后端 API 绝对地址，用于前端静态托管（Cloudflare）而 API 在 Railway 的场景。
   * 例：https://autoclip-api.up.railway.app/api/v1（只写域名时会自动补 /api/v1）。
   * 留空则使用相对路径 /api/v1（桌面端 / Docker / 本地开发）。
   */
  readonly VITE_API_BASE_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

declare module '*.svg' {
  const content: string
  export default content
}

declare module '*.webm?url' {
  const src: string
  export default src
}

declare module '*.mp4?url' {
  const src: string
  export default src
}

declare module '*.svg?react' {
  import React from 'react'
  const ReactComponent: React.FunctionComponent<React.SVGProps<SVGSVGElement>>
  export default ReactComponent
}