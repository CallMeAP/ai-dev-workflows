declare module 'claude-code' {
  interface PluginState {
    'christmas-lights': {
      // Whether /christmas has switched the scene on in this session.
      isOn: boolean
      // How full the context window is, 0 to 100: the snow lies deeper as it fills.
      percent: number
      // How far the lights have chased along the wire. Bumped once a turn.
      phase: number
      // The scene's own slow clock: snow falls and Santa flies by it.
      tick: number
    }
  }
}
