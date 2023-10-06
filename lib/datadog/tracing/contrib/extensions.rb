require 'set'

require_relative '../../core/configuration/settings'
require_relative 'kernel'

# Datadog
module Datadog
  # Datadog tracing
  module Tracing
    module Contrib
      # Extensions that can be added to the base library
      # Adds registry, configuration access for integrations.
      #
      # DEV: The Registry should probably be part of the core tracer
      # as it represents a global tracer repository that is strongly intertwined
      # with the tracer lifecycle and deeply modifies the tracer initialization
      # process.
      # Most of this file should probably live inside the tracer core.
      module Extensions
        def self.extend!
          Datadog.singleton_class.prepend Helpers
          Datadog.singleton_class.prepend Configuration

          # DEV: We want settings to only apply to the `tracing` subgroup.
          #      Until we have a better API of accessing that settings class,
          #      we have to dig into it like this.
          settings_class = Core::Configuration::Settings.options[:tracing].default.call.class
          settings_class.include(Configuration::Settings)
        end

        # Helper methods for Datadog module.
        module Helpers
          # The global integration registry.
          #
          # This registry holds a reference to all integrations available
          # to the tracer.
          #
          # Integrations registered in the {.registry} can be activated as follows:
          #
          # ```
          # Datadog.configure do |c|
          #   c.tracing.instrument :my_registered_integration, **my_options
          # end
          # ```
          #
          # New integrations can be registered by implementing the {Datadog::Tracing::Contrib::Integration} interface.
          #
          # @return [Datadog::Tracing::Contrib::Registry]
          # @!attribute [r] registry
          # @public_api
          def registry
            Contrib::REGISTRY
          end
        end

        # Configuration methods for Datadog module.
        module Configuration
          # TODO: Is is not possible to separate this configuration method
          # TODO: from core ddtrace parts ()e.g. the registry).
          # TODO: Today this method sits here in the `Datadog::Tracing::Contrib::Extensions` namespace
          # TODO: but cannot empirically constraints to the contrib domain only.
          # TODO: We should promote most of this logic to core parts of ddtrace.
          def configure(&block)
            # Reconfigure core settings
            super(&block)

            # Activate integrations
            configuration = self.configuration.tracing

            if configuration.respond_to?(:integrations_pending_activation)
              Datadog::Tracing::Contrib::Kernel.patch! # Only needs to run once

              ignore_integration_load_errors = if configuration.respond_to?(:ignore_integration_load_errors?)
                                                 configuration.ignore_integration_load_errors?
                                               else
                                                 false
                                               end

              configuration.integrations_pending_activation.each do |integration|
                patch_integration(integration, ignore_integration_load_errors) do
                  # Do compatible gem exist in the current environment, but are not loaded yet?
                  if integration.class.available? && integration.class.compatible? && !integration.class.loaded?
                    Datadog.logger.debug { "Gems '#{integration.gems.join(',')}' not loaded, monitoring loading." }

                    integration.gems.each do |gem|
                      Datadog::Tracing::Contrib::Kernel.on_require(gem) do
                        Datadog.logger.debug do
                          "Gem '#{gem}' loaded for integration '#{integration.name}', instrumenting it."
                        end

                        patch_integration(integration, ignore_integration_load_errors)
                      end
                    end

                    # Try to instrument one more time, in case another threaded loaded this
                    # integration's gems while we were registering the monitor.
                    if integration.class.loaded?
                      patch_integration(integration, ignore_integration_load_errors)
                      next
                    end
                  end
                end
              end

              components.telemetry.integrations_change! if configuration.integrations_pending_activation

              configuration.integrations_pending_activation.clear
            end

            configuration
          end

          private

          def patch_integration(integration, ignore_integration_load_errors, &fallback)
            return unless integration.respond_to?(:patch)

            # integration.patch returns either true or a hash of details on why patching failed
            patch_results = integration.patch

            return if patch_results == true

            # Try to patch it with another approach. Do not report patching
            # errors at this point, as we haven't given up yet.
            return yield if fallback

            # if patching failed, only log output if verbosity is unset
            # or if patching failure is due to compatibility or integration specific reasons
            return unless !ignore_integration_load_errors ||
              ((patch_results[:available] && patch_results[:loaded]) &&
                (!patch_results[:compatible] || !patch_results[:patchable]))

            desc = "Available?: #{patch_results[:available]}"
            desc += ", Loaded? #{patch_results[:loaded]}"
            desc += ", Compatible? #{patch_results[:compatible]}"
            desc += ", Patchable? #{patch_results[:patchable]}"

            Datadog.logger.warn("Unable to patch #{patch_results[:name]} (#{desc})")
          end

          # Extensions for Datadog::Core::Configuration::Settings
          # @public_api
          module Settings
            InvalidIntegrationError = Class.new(StandardError)

            def self.included(base)
              base.class_eval do
                settings :contrib do
                  # Key-value map for explicitly re-mapping peer.service values
                  #
                  # @default `DD_TRACE_PEER_SERVICE_MAPPING` environment variable converted to hash
                  # @return [Hash]
                  option :peer_service_mapping do |o|
                    o.env Tracing::Configuration::Ext::SpanAttributeSchema::ENV_PEER_SERVICE_MAPPING
                    o.type :hash
                    o.default({})
                  end

                  # Global service name behavior
                  settings :global_default_service_name do
                    # Overrides default service name to global service name
                    #
                    # Allows for usage of v1 service name changes without
                    # being forced to update schema versions
                    #
                    # @default `DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED` environment variable, otherwise `false`
                    # @return [Boolean]
                    option :enabled do |o|
                      o.env Tracing::Configuration::Ext::SpanAttributeSchema::ENV_GLOBAL_DEFAULT_SERVICE_NAME_ENABLED
                      o.type :bool
                      o.default false
                    end
                  end
                end
              end
            end

            # Applies instrumentation for the provided `integration_name`.
            #
            # Options may be provided, that are specific to that instrumentation.
            # See the instrumentation's settings file for a list of available options.
            #
            # @example
            #   Datadog.configure { |c| c.tracing.instrument :integration_name }
            # @example
            #   Datadog.configure { |c| c.tracing.instrument :integration_name, option_key: :option_value }
            # @param [Symbol] integration_name the integration name
            # @param [Hash] options the integration-specific configuration settings
            # @return [Datadog::Tracing::Contrib::Integration]
            def instrument(integration_name, options = {}, &block)
              integration = fetch_integration(integration_name)

              unless integration.nil? || !integration.default_configuration.enabled
                configuration_name = options[:describes] || :default
                filtered_options = options.reject { |k, _v| k == :describes }
                integration.configure(configuration_name, filtered_options, &block)
                instrumented_integrations[integration_name] = integration

                # Add to activation list
                integrations_pending_activation << integration
              end

              integration
            end

            # TODO: Deprecate in the next major version, as `instrument` better describes this method's purpose
            alias_method :use, :instrument

            # For the provided `integration_name`, resolves a matching configuration
            # for the provided integration from an integration-specific `key`.
            #
            # How the matching is performed is integration-specific.
            #
            # @example
            #   Datadog.configuration.tracing[:integration_name]
            # @example
            #   Datadog.configuration.tracing[:integration_name][:sub_configuration]
            # @param [Symbol] integration_name the integration name
            # @param [Object] key the integration-specific lookup key
            # @return [Datadog::Tracing::Contrib::Configuration::Settings]
            def [](integration_name, key = :default)
              integration = fetch_integration(integration_name)
              integration.resolve(key) unless integration.nil?
            end

            # @!visibility private
            def integrations_pending_activation
              @integrations_pending_activation ||= Set.new
            end

            # @!visibility private
            def instrumented_integrations
              @instrumented_integrations ||= {}
            end

            # @!visibility private
            def reset!
              instrumented_integrations.clear
              super
            end

            # @!visibility private
            def fetch_integration(name)
              Contrib::REGISTRY[name] ||
                raise(InvalidIntegrationError, "'#{name}' is not a valid integration.")
            end

            # @!visibility private
            def ignore_integration_load_errors?
              defined?(@ignore_integration_load_errors) ? @ignore_integration_load_errors == true : false
            end

            def ignore_integration_load_errors=(value)
              @ignore_integration_load_errors = value
            end
          end
        end
      end
    end
  end

  # Load built-in Datadog integrations
  Tracing::Contrib::Extensions.extend!
end
