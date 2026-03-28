<script setup>
import { onMounted, ref } from 'vue'

const visible = ref(false)
onMounted(() => {
  requestAnimationFrame(() => { visible.value = true })
})
</script>

<template>
  <div class="custom-home" :class="{ visible }">
    <section class="hero">
      <div class="hero-content">
        <div class="hero-text">
          <h1 class="title">Typelizer</h1>
          <p class="tagline">Define once in Ruby. Generate everywhere in TypeScript.</p>
          <p class="subtitle">For Rails apps using Alba, AMS, Oj, or Panko serializers.</p>
          <div class="actions">
            <a class="action-btn primary" href="/getting-started">
              Get Started
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M12 5l7 7-7 7"/></svg>
            </a>
            <a class="action-btn secondary" href="https://github.com/skryukov/typelizer" target="_blank" rel="noopener">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/></svg>
              GitHub
            </a>
          </div>
        </div>
        <div class="hero-code">
          <div class="code-pair">
            <div class="code-block ruby-block">
              <div class="code-header">
                <div class="code-dots">
                  <span class="code-dot"></span>
                  <span class="code-dot"></span>
                  <span class="code-dot"></span>
                </div>
                <span class="code-label">post_resource.rb</span>
              </div>
              <pre><code><span class="kw">class</span> <span class="cn">PostResource</span> <span class="op">&lt;</span> <span class="cn">ApplicationResource</span>
  <span class="kw">include</span> <span class="cn">Typelizer::DSL</span>

  attributes <span class="sy">:id</span>, <span class="sy">:title</span>, <span class="sy">:body</span>

  has_one <span class="sy">:author</span>
  has_many <span class="sy">:comments</span>
<span class="kw">end</span></code></pre>
            </div>
            <div class="arrow-container">
              <div class="arrow">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M5 12h14M12 5l7 7-7 7"/>
                </svg>
              </div>
            </div>
            <div class="code-block ts-block">
              <div class="code-header">
                <div class="code-dots">
                  <span class="code-dot"></span>
                  <span class="code-dot"></span>
                  <span class="code-dot"></span>
                </div>
                <span class="code-label">Post.ts</span>
                <span class="code-tag">generated</span>
              </div>
              <pre><code><span class="kw">export interface</span> <span class="cn">Post</span> {
  <span class="pr">id</span>: <span class="ty">number</span>;
  <span class="pr">title</span>: <span class="ty">string</span>;
  <span class="pr">body</span>: <span class="ty">string</span>;
  <span class="pr">author</span>: <span class="ty">Author</span>;
  <span class="pr">comments</span>: <span class="ty">Array</span>&lt;<span class="ty">Comment</span>&gt;;
}</code></pre>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class="features">
      <div class="features-grid">
        <div class="feature">
          <h3>Works With Your Serializer</h3>
          <p>Supports Alba, ActiveModel::Serializer, Oj::Serializer, and Panko out of the box.</p>
        </div>
        <div class="feature">
          <h3>Type-Safe Route Helpers</h3>
          <p>Import your Rails routes as typed functions. Params are checked, paths are built -- no strings to get wrong.</p>
        </div>
        <div class="feature">
          <h3>Multiple Writers</h3>
          <p>Need snake_case for one app and camelCase for another? Define multiple writers, generate both at once.</p>
        </div>
        <div class="feature">
          <h3>Auto-Regeneration</h3>
          <p>Change a serializer, types regenerate. Edit routes.rb, route helpers update. Zero manual steps in development.</p>
        </div>
        <div class="feature">
          <h3>OpenAPI Schemas</h3>
          <p>Turn the same serializer definitions into OpenAPI 3.0 or 3.1 component schemas for your API docs.</p>
        </div>
        <div class="feature">
          <h3>Layered Configuration</h3>
          <p>Configure globally, per-writer, or per-serializer. Sensible defaults, full control when you need it.</p>
        </div>
      </div>
    </section>

  </div>
</template>

<style scoped>
.custom-home {
  max-width: 1152px;
  margin: 0 auto;
  padding: 0 24px;
}

/* ── Entrance animations ── */
.custom-home .hero-text,
.custom-home .ruby-block,
.custom-home .arrow-container,
.custom-home .ts-block,
.custom-home .features {
  opacity: 0;
  transform: translateY(12px);
  transition: opacity 0.5s ease, transform 0.5s ease;
}

.custom-home.visible .hero-text       { opacity: 1; transform: none; transition-delay: 0s; }
.custom-home.visible .ruby-block      { opacity: 1; transform: none; transition-delay: 0.1s; }
.custom-home.visible .arrow-container { opacity: 1; transform: none; transition-delay: 0.2s; }
.custom-home.visible .ts-block        { opacity: 1; transform: none; transition-delay: 0.3s; }
.custom-home.visible .features        { opacity: 1; transform: none; transition-delay: 0.4s; }

@media (prefers-reduced-motion: reduce) {
  .custom-home .hero-text,
  .custom-home .ruby-block,
  .custom-home .arrow-container,
  .custom-home .ts-block,
  .custom-home .features {
    opacity: 1;
    transform: none;
    transition: none;
  }
}

/* ── Hero ── */
.hero {
  padding: 72px 0 56px;
}

.hero-content {
  display: flex;
  flex-direction: column;
  gap: 40px;
}

.hero-text {
  text-align: center;
  max-width: 560px;
  margin: 0 auto;
}

.title {
  font-size: 48px;
  font-weight: 800;
  letter-spacing: -0.035em;
  line-height: 1.05;
  color: var(--vp-c-text-1);
}

.tagline {
  font-size: 18px;
  line-height: 1.6;
  color: var(--vp-c-text-2);
  margin-top: 16px;
  letter-spacing: -0.01em;
}

.subtitle {
  font-size: 14px;
  color: var(--vp-c-text-3);
  margin-top: 8px;
}

.actions {
  display: flex;
  justify-content: center;
  gap: 12px;
  margin-top: 28px;
}

.action-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 10px 20px;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  text-decoration: none;
  transition: all 0.15s ease;
  letter-spacing: -0.01em;
}

.action-btn.primary {
  background: var(--vp-c-brand-3);
  color: var(--vp-c-white);
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
}

.action-btn.primary:hover {
  background: var(--vp-c-brand-2);
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
}

.action-btn.secondary {
  border: 1px solid var(--vp-c-divider);
  color: var(--vp-c-text-2);
  background: var(--vp-c-bg-soft);
}

.action-btn.secondary:hover {
  border-color: var(--vp-c-text-3);
  color: var(--vp-c-text-1);
}

/* ── Code pair ── */
.hero-code {
  width: 100%;
}

.code-pair {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0;
}

.arrow-container {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 8px 0;
}

.arrow {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-divider);
  color: var(--vp-c-text-3);
  transform: rotate(90deg);
}

.code-block {
  width: 100%;
  border-radius: 12px;
  border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft);
  overflow: hidden;
  transition: border-color 0.2s ease;
}

.code-block:hover {
  border-color: var(--vp-c-brand-soft);
}

.code-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 16px;
  border-bottom: 1px solid var(--vp-c-divider);
}

.code-dots {
  display: flex;
  gap: 5px;
}

.code-dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  background: var(--vp-c-divider);
}

.code-label {
  font-size: 12px;
  font-weight: 500;
  color: var(--vp-c-text-2);
  font-family: var(--vp-font-family-mono);
  letter-spacing: 0.01em;
}

.code-tag {
  margin-left: auto;
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--vp-c-brand-1);
  background: var(--vp-c-brand-soft);
  padding: 2px 8px;
  border-radius: 4px;
}

.code-block pre {
  margin: 0;
  padding: 16px 20px;
  overflow-x: auto;
}

.code-block code {
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  line-height: 1.75;
  color: var(--vp-c-text-1);
}

/* ── Syntax highlighting ── */
.kw { color: var(--vp-c-brand-1); font-weight: 500; }
.cn { color: var(--vp-c-green-1, #42b883); }
.sy { color: var(--vp-c-yellow-1, #e5c07b); }
.op { color: var(--vp-c-text-3); }
.pr { color: var(--vp-c-text-1); }
.ty { color: var(--vp-c-brand-2); }

/* ── Features ── */
.features {
  padding: 56px 0;
  border-top: 1px solid var(--vp-c-divider);
}

.features-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 16px;
}

.feature {
  padding: 24px;
  border-radius: 12px;
  border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft);
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}

.feature:hover {
  border-color: var(--vp-c-brand-soft);
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.04);
}

.feature h3 {
  font-size: 15px;
  font-weight: 600;
  color: var(--vp-c-text-1);
  margin: 0 0 8px;
  letter-spacing: -0.01em;
}

.feature p {
  font-size: 14px;
  line-height: 1.6;
  color: var(--vp-c-text-2);
  margin: 0;
}

/* ── Responsive ── */
@media (min-width: 640px) {
  .features-grid {
    grid-template-columns: repeat(2, 1fr);
  }
}

@media (min-width: 640px) {
  .code-pair {
    flex-direction: row;
    gap: 0;
  }

  .arrow-container {
    padding: 0 12px;
  }

  .arrow {
    transform: none;
  }
}

@media (min-width: 768px) {
  .title {
    font-size: 56px;
  }
}

@media (min-width: 960px) {
  .hero {
    padding: 88px 0 64px;
  }

  .features-grid {
    grid-template-columns: repeat(3, 1fr);
  }
}
</style>
