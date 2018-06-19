# frozen_string_literal: true

module Hyrax
  module Actors

    class AfterOptimisticLockValidator < AbstractEventActor

      # @param [Hyrax::Actors::Environment] env
      # @return [Boolean] true if create was successful
      def create( env )
        log_event( env: env, event: :create )
        next_actor.create( env )
      end

      # @param [Hyrax::Actors::Environment] env
      # @return [Boolean] true if destroy was successful
      def destroy( env )
        log_event( env: env, event: :destroy )
        next_actor.destroy( env )
      end

      # @param [Hyrax::Actors::Environment] env
      # @return [Boolean] true if update was successful
      def update( env )
        log_event( env: env, event: :update )
        next_actor.update( env )
      end

      protected

        def log_event( env:, event: )
          actor = next_actor
          msg = "AfterOptimisticLockValidator.#{event}: env.curation_concern.class=#{env.curation_concern.class.name} next_actor=#{actor.class.name} env.attributes=#{ActiveSupport::JSON.encode env.attributes}"
          Deepblue::LoggingHelper.bold_debug( msg, lines: 2 )
        end

    end

  end
end
