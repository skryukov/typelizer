import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Typelizer',
  description: 'Generate TypeScript types, route helpers, and OpenAPI schemas from Ruby on Rails',

  themeConfig: {
    nav: [
      { text: 'Guide', link: '/getting-started' },
      { text: 'Reference', link: '/reference/configuration' },
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Getting Started', link: '/getting-started' },
        ],
      },
      {
        text: 'Serializers',
        items: [
          { text: 'Alba', link: '/guides/alba' },
          { text: 'ActiveModel::Serializer', link: '/guides/ams' },
          { text: 'Oj::Serializer', link: '/guides/oj-serializer' },
          { text: 'Panko::Serializer', link: '/guides/panko' },
        ],
      },
      {
        text: 'Guides',
        items: [
          { text: 'Manual Typing', link: '/guides/manual-typing' },
          { text: 'Multiple Writers', link: '/guides/multiple-writers' },
          { text: 'OpenAPI Schemas', link: '/guides/openapi' },
          { text: 'Route Helpers', link: '/guides/routes' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Configuration', link: '/reference/configuration' },
          { text: 'Route API', link: '/reference/route-api' },
          { text: 'Type Mapping', link: '/reference/type-mapping' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/skryukov/typelizer' },
    ],

    search: {
      provider: 'local',
    },

    editLink: {
      pattern: 'https://github.com/skryukov/typelizer/edit/main/docs/:path',
    },
  },
})
