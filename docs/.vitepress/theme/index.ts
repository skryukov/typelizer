import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import CustomHome from './CustomHome.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  Layout: () => {
    return h(DefaultTheme.Layout, null, {
      'home-features-after': () => null,
    })
  },
  enhanceApp({ app }) {
    app.component('CustomHome', CustomHome)
  }
} satisfies Theme
