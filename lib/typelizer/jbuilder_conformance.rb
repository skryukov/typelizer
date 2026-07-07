# frozen_string_literal: true

require_relative "conformance"

module Typelizer
  module Jbuilder
    # Maps rendered jbuilder templates to their registered Typelizer
    # interfaces and validates the response body against them — the runtime
    # half of the differential loop: the walker promises a type statically,
    # this checks the promise against what actually rendered.
    #
    # Opt-in, test-mode usage (e.g. in rails_helper):
    #
    #   Typelizer::Jbuilder::Conformance.subscribe!
    #
    #   # in a request spec, after a request that rendered jbuilder:
    #   Typelizer::Jbuilder::Conformance.validate_last_render!(response.body)
    #
    # `subscribe!` listens to ActionView's render notifications and remembers
    # the last .json.jbuilder template rendered on the current thread;
    # `validate_last_render!` raises Typelizer::Conformance::Mismatch with
    # every violation when the body does not conform.
    module Conformance
      EVENT = "render_template.action_view"
      THREAD_KEY = :typelizer_jbuilder_last_template

      module_function

      def subscribe!
        @subscriber ||= ActiveSupport::Notifications.subscribe(EVENT) do |*, payload|
          identifier = payload[:identifier].to_s
          Thread.current[THREAD_KEY] = identifier if identifier.end_with?(".json.jbuilder")
        end
      end

      def unsubscribe!
        ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        @subscriber = nil
        @interfaces = nil
        Thread.current[THREAD_KEY] = nil
      end

      def last_template_path
        Thread.current[THREAD_KEY]
      end

      def validate_last_render!(body, views_root: nil)
        path = last_template_path
        unless path
          raise Typelizer::Error, "Typelizer::Jbuilder::Conformance: no jbuilder template was rendered " \
            "on this thread (did you call subscribe! before the request?)"
        end

        klass = lookup_template(path, views_root)
        unless klass
          raise Typelizer::Error, "Typelizer::Jbuilder::Conformance: #{path} is not a registered " \
            "Typelizer template (run discovery for its views root first)"
        end

        rendered = body.is_a?(String) ? JSON.parse(body) : body
        Typelizer::Conformance.check!(interface_for(klass), rendered, source: path)
      end

      # Returns violations instead of raising — for collecting across a suite.
      def validate_last_render(body, views_root: nil)
        validate_last_render!(body, views_root: views_root)
        []
      rescue Typelizer::Conformance::Mismatch => e
        e.violations
      end

      def lookup_template(path, views_root)
        candidates = [path]
        begin
          candidates << File.realpath(path)
        rescue Errno::ENOENT
          # deleted between render and validation — registry lookup only
        end
        candidates.uniq.each do |candidate|
          klass = Typelizer::Jbuilder.registry[candidate] ||
            (views_root ? Typelizer::Jbuilder.template_for(candidate, views_root: views_root) : Typelizer::Jbuilder.template_for(candidate))
          return klass if klass
        end
        nil
      end

      def interface_for(klass)
        @interfaces ||= {}
        @interfaces[klass] ||= Typelizer::WriterContext.new(writer_name: nil).interface_for(klass)
      end
    end
  end
end
