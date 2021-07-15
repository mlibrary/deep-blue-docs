# frozen_string_literal: true

module Deepblue

  module AnonymousLinkControllerBehavior

    mattr_accessor :anonymous_link_controller_behavior_debug_verbose,
                   default: ::DeepBlueDocs::Application.config.anonymous_link_controller_behavior_debug_verbose

    INVALID_ANONYMOUS_LINK = ''.freeze

    include ActionView::Helpers::TranslationHelper

    def render_anonymous_error( exception )
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "" ] if anonymous_link_controller_behavior_debug_verbose
      if anonymous_link_controller_behavior_debug_verbose
        logger.error( "Rendering PAGE due to exception: #{exception.inspect} - #{exception.backtrace[0..10] if exception.respond_to? :backtrace}" )
      end
      # render 'anonymous_error', layout: "error", status: 404
      redirect_to main_app.root_path, alert: anonymous_link_expired_msg
    end

    def anonymous_link_destroy!( su_link )
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "su_link=#{su_link}",
                                             "::Hyrax::AnonymousLinkService.anonymous_link_but_not_really=#{::Hyrax::AnonymousLinkService.config.anonymous_link_but_not_really}",
                                             "" ] if anonymous_link_controller_behavior_debug_verbose
      return if ::Hyrax::AnonymousLinkService.anonymous_link_but_not_really
      return unless su_link.is_a? AnonymousLink
      rv = su_link.destroy!
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "rv = su_link.destroy!=#{rv}",
                                             "" ] if anonymous_link_controller_behavior_debug_verbose
      return rv
    end

    def anonymous_link_expired_msg
      t('hyrax.anonymous_links.expired_html')
    end

    def anonymous_link_obj( link_id: )
      @anonymous_link_obj ||= find_anonymous_link_obj( link_id: link_id )
    end

    def anonymous_link_valid?( su_link, item_id: nil, path: nil, destroy_if_not_valid: false )
      return false unless su_link.is_a? AnonymousLink
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "su_link.valid?=#{su_link.valid?}",
                                             "su_link.itemId=#{su_link.itemId}",
                                             "su_link.path=#{su_link.path}",
                                             "item_id=#{item_id}",
                                             "path=#{path}",
                                             "destroy_if_not_valid=#{destroy_if_not_valid}",
                                             "" ] if anonymous_link_controller_behavior_debug_verbose
      return destroy_and_return_rv( destroy_flag: destroy_if_not_valid, rv: false, su_link: su_link ) unless su_link.valid?
      if item_id.present?
        ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                               ::Deepblue::LoggingHelper.called_from,
                                               "item_id=#{item_id}",
                                               "su_link.itemId=#{su_link.itemId}",
                                               "destroy unless?=#{su_link.itemId == item_id}",
                                               "" ] if anonymous_link_controller_behavior_debug_verbose
        return destroy_and_return_rv( destroy_flag: destroy_if_not_valid, rv: false, su_link: su_link ) unless su_link.itemId == item_id
      end
      if path.present?
        su_link_path = su_link_strip_locale su_link.path
        path = su_link_strip_locale path
        ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                               ::Deepblue::LoggingHelper.called_from,
                                               "path=#{path}",
                                               "su_link_path=#{su_link_path}",
                                               "destroy unless?=#{su_link_path == path}",
                                               "" ] if anonymous_link_controller_behavior_debug_verbose
        return destroy_and_return_rv( destroy_flag: destroy_if_not_valid, rv: false, su_link: su_link ) unless su_link_path == path
      end
      return true
    end

    private

      def destroy_and_return_rv( destroy_flag:, rv:, su_link: )
        ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                               ::Deepblue::LoggingHelper.called_from,
                                               "rv=#{rv}",
                                               "destroy_flag=#{destroy_flag}",
                                               "" ] if anonymous_link_controller_behavior_debug_verbose
        return rv unless destroy_flag
        anonymous_link_destroy! su_link
        return rv
      end

      def find_anonymous_link_obj( link_id: )
        return INVALID_ANONYMOUS_LINK if link_id.blank?
        rv = AnonymousLink.find_by_downloadKey!( link_id )
        return rv
      rescue ActiveRecord::RecordNotFound => _ignore
        return INVALID_ANONYMOUS_LINK # blank, so we only try looking it up once
      end

      def su_link_strip_locale( path )
        if path =~ /^(.+)\?.+/
          return Regexp.last_match[1]
        end
        return path
      end

  end

end