# frozen_string_literal: true

RSpec.describe Typelizer::RouteGenerator, type: :typelizer do
  let(:configuration) { Typelizer.configuration }
  let(:route_config) { configuration.routes }
  let(:output_dir) { Rails.root.join("tmp/test_routes") }

  around do |ex|
    route_config.enabled = true
    route_config.output_dir = output_dir
    ex.call
    route_config.enabled = false
    route_config.output_dir = nil
    route_config.include = nil
    route_config.exclude = nil
    route_config.format = :ts
    FileUtils.rm_rf(output_dir)
  end

  describe "#call" do
    subject(:generator) { described_class.new }

    it "generates per-controller route files" do
      generator.call(force: true)

      expect(output_dir.join("UsersController.ts")).to exist
      expect(output_dir.join("PostsController.ts")).to exist
      expect(output_dir.join("Admin/UsersController.ts")).to exist
    end

    it "generates runtime.ts" do
      generator.call(force: true)

      runtime = File.read(output_dir.join("runtime.ts"))
      expect(runtime).to include("export type RouteDefinition")
      expect(runtime).to include("export function buildUrl")
      expect(runtime).to include("function buildQuery")
    end

    it "generates index.ts barrel with namespaced exports" do
      generator.call(force: true)

      index = File.read(output_dir.join("index.ts"))
      expect(index).to include("export { default as users } from './UsersController'")
      expect(index).to include("export { default as posts } from './PostsController'")
      expect(index).to include("export { default as adminUsers } from './Admin/UsersController'")
    end

    it "generates named routes" do
      generator.call(force: true)

      index = File.read(output_dir.join("index.ts"))
      expect(index).to include("export const root = ")
      expect(index).to include("export const archive = ")
    end

    it "generates POST, PATCH, DELETE routes" do
      generator.call(force: true)

      users = File.read(output_dir.join("UsersController.ts"))
      expect(users).to include("method: 'post'")
      expect(users).to include("method: 'patch'")
      expect(users).to include("method: 'delete'")
      # PUT is skipped (PATCH is canonical)
      expect(users).not_to include("method: 'put'")
    end

    it "emits all routes as plain callables (no form variant)" do
      generator.call(force: true)

      users = File.read(output_dir.join("UsersController.ts"))
      expect(users).not_to include("Object.assign")
      expect(users).not_to include("formAction")
      expect(users).not_to include("FormDefinition")
      expect(users).not_to include("_method")
    end

    it "generates runtime with URL defaults and base URL helpers only" do
      generator.call(force: true)

      runtime = File.read(output_dir.join("runtime.ts"))
      expect(runtime).not_to include("FormDefinition")
      expect(runtime).not_to include("formAction")
      expect(runtime).to include("export function setUrlDefaults")
      expect(runtime).to include("export function addUrlDefault")
      expect(runtime).to include("export function setBaseUrl")
    end

    it "generates typed route helpers with params" do
      generator.call(force: true)

      users = File.read(output_dir.join("UsersController.ts"))
      # show action should have id param
      expect(users).to include("id: string | number")
      expect(users).to include("'/users/:id'")
      expect(users).to include("method: 'get'")

      # index action should have no required params
      expect(users).to include("options?: RouteOptions): RouteDefinition<'get'>")
    end

    it "generates nested resource routes" do
      generator.call(force: true)

      # user_posts should be in PostsController (or a nested controller)
      # The routes are named user_posts and user_post
      posts = File.read(output_dir.join("PostsController.ts"))
      expect(posts).to include("'/posts/:id'")
    end

    it "generates admin namespaced routes" do
      generator.call(force: true)

      admin = File.read(output_dir.join("Admin/UsersController.ts"))
      expect(admin).to include("'/admin/users'")
      expect(admin).to include("'/admin/users/:id'")
      expect(admin).to include("method: 'get'")
    end

    it "generates optional param routes" do
      generator.call(force: true)

      posts = File.read(output_dir.join("PostsController.ts"))
      expect(posts).to include("year?: string | number")
      expect(posts).to include("month?: string | number")
    end

    it "generates glob param routes" do
      generator.call(force: true)

      pages = File.read(output_dir.join("PagesController.ts"))
      expect(pages).to include("path: string | number")
      expect(pages).to include("'*path'").or include("*path")
    end

    it "skips generation when routes.enabled is false" do
      route_config.enabled = false

      generator.call(force: true)

      expect(output_dir).not_to exist
    end

    it "applies exclude filter" do
      route_config.exclude = /\/admin\//

      generator.call(force: true)

      expect(output_dir.join("Admin/UsersController.ts")).not_to exist
      expect(output_dir.join("UsersController.ts")).to exist
    end

    it "generates mounted engine routes with mount prefix" do
      generator.call(force: true)

      # Engine controller file should be generated
      engine_file = output_dir.join("BlogEngine/ArticlesController.ts")
      expect(engine_file).to exist

      content = File.read(engine_file)
      # Paths should include the mount prefix
      expect(content).to include("'/blog/articles'")
      expect(content).to include("'/blog/articles/:id'")
      expect(content).to include("method: 'get'")

      # Index should include the engine namespace
      index = File.read(output_dir.join("index.ts"))
      expect(index).to include("blogEngineArticles")

      # Named route exports (engine-prefixed name collides with controller namespace,
      # so the shorter action-based name is used)
      expect(index).to include("export const articles = _blogEngineArticles.index")
      expect(index).to include("export const article = _blogEngineArticles.show")
    end

    it "uses fingerprint caching to skip unchanged files" do
      generator.call(force: true)

      # Get mtime of a generated file
      file = output_dir.join("UsersController.ts")
      mtime = File.mtime(file)

      sleep 0.1
      generator.call(force: false)

      # File should not have been rewritten
      expect(File.mtime(file)).to eq(mtime)
    end

    context "with format: :js" do
      before { route_config.format = :js }

      it "generates .js files instead of .ts" do
        generator.call(force: true)

        expect(output_dir.join("UsersController.js")).to exist
        expect(output_dir.join("runtime.js")).to exist
        expect(output_dir.join("index.js")).to exist
        expect(output_dir.join("UsersController.ts")).not_to exist
      end

      it "generates runtime without type annotations" do
        generator.call(force: true)

        runtime = File.read(output_dir.join("runtime.js"))
        expect(runtime).to include("export function buildUrl")
        expect(runtime).not_to include("export type")
        expect(runtime).not_to include(": string")
        expect(runtime).not_to include("Record<string, unknown>")
        expect(runtime).not_to include("as Record<string, unknown>")
      end

      it "generates controllers without type annotations" do
        generator.call(force: true)

        users = File.read(output_dir.join("UsersController.js"))
        expect(users).to include("import { buildUrl }")
        expect(users).not_to include("import type")
        expect(users).not_to include("formAction")
        expect(users).not_to include("RouteDefinition")
        expect(users).not_to include("FormDefinition")
        expect(users).not_to include("RouteOptions")
        expect(users).not_to include(": string | number")
        expect(users).to include("method: 'get'")
        expect(users).to include("method: 'post'")
      end
    end
  end
end
