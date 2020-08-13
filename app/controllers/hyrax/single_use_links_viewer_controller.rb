# frozen_string_literal: true

module Hyrax

  class SingleUseLinksViewerController < DownloadsController

    SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE = ::DeepBlueDocs::Application.config.single_use_links_viewer_controller_debug_verbose

    include Blacklight::Base
    include Blacklight::AccessControls::Catalog
    include ActionDispatch::Routing::PolymorphicRoutes
    include Deepblue::SingleUseLinkControllerBehavior

    skip_before_action :authorize_download!, only: :show
    rescue_from SingleUseError, with: :render_single_use_error
    rescue_from CanCan::AccessDenied, with: :render_single_use_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_single_use_error
    class_attribute :presenter_class
    self.presenter_class = DsFileSetPresenter
    copy_blacklight_config_from(::CatalogController)

    def download
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "single_use_link=#{single_use_link}",
                                             "single_use_link.path=#{single_use_link.path}",
                                             "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
      raise not_found_exception unless single_use_link_valid?( single_use_link, destroy_if_not_valid: true )
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "single_use_link=#{single_use_link}",
                                             "single_use_link.path=#{single_use_link.path}",
                                             "asset&.id=#{asset&.id}",
                                             # "hyrax.download_path(id: asset)=#{hyrax.download_path(id: asset)}",
                                             "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
      raise not_found_exception unless single_use_link_valid?( single_use_link, item_id: asset&.id, destroy_if_not_valid: true )
      single_use_link_destroy! single_use_link
      send_content
    end

    def show
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "params[:id]=#{params[:id]}",
                                             "single_use_link.class.name=#{single_use_link.class.name}",
                                             "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
      raise not_found_exception unless single_use_link_valid?( single_use_link, destroy_if_not_valid: true )
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "params[:id]=#{params[:id]}",
                                             "single_use_link.itemId=#{single_use_link.itemId}",
                                             "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
      _, document_list = search_results( id: single_use_link.itemId )
      solr_doc = document_list.first
      model = solr_doc['has_model_ssim'].first
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "model=#{model}",
                                             "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
      url = if 'FileSet' == model
              # TODO: properly generate this route
              "/data/concern/file_sets/#{solr_doc.id}/single_use_link/#{params[:id]}"
            else
              # TODO: properly generate this route
              "/data/concern/data_sets/#{solr_doc.id}/single_use_link/#{params[:id]}"
            end
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "url=#{url}",
                                             "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
      redirect_to url
    end

    private

      def search_builder_class
        SingleUseLinkSearchBuilder
      end

      def content_options
        super.tap do |options|
          options[:disposition] = 'attachment' if action_name == 'download'
        end
      end

      # This is called in a before filter. It causes @asset to be set.
      def authorize_download!
        authorize! :read, asset
      end

      def single_use_link
        @single_use_link ||= single_use_link_obj( link_id: params[:id] )
      end

      def not_found_exception
        SingleUseError.new('Single-Use Link Not Found')
      end

      def asset
        @asset ||= if single_use_link.is_a? SingleUseLink
                     ActiveFedora::Base.find(single_use_link.itemId)
                   else
                     ''
                   end
      end

      def current_ability
        ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                               ::Deepblue::LoggingHelper.called_from,
                                               "current_user=#{current_user}",
                                               "single_use_link=#{single_use_link}",
                                               "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
        @current_ability ||= SingleUseLinksViewerController::Ability.new current_user, single_use_link
      end

      def _prefixes
        # This allows us to use the attributes templates in hyrax/base, while prefering
        # our local paths. Thus we are unable to just override `self.local_prefixes`
        @_prefixes ||= super + ['hyrax/base']
      end

      class Ability
        include CanCan::Ability

        attr_reader :single_use_link

        def initialize(user, single_use_link)
          ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                                 ::Deepblue::LoggingHelper.called_from,
                                                 "user=#{user}",
                                                 "single_use_link=#{single_use_link}",
                                                 "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
          @user = user || ::User.new
          return if single_use_link.blank?

          @single_use_link = single_use_link
          can :read, [ActiveFedora::Base, ::SolrDocument] do |obj|
            ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                                   ::Deepblue::LoggingHelper.called_from,
                                                   "single_use_link&.valid?=#{single_use_link&.valid?}",
                                                   "single_use_link&.itemId=#{single_use_link&.itemId}",
                                                   "obj.id=#{obj.id}",
                                                   "" ] if SINGLE_USE_LINKS_VIEWER_CONTROLLER_DEBUG_VERBOSE
            single_use_link.valid? && single_use_link.itemId == obj.id # && single_use_link.destroy!
          end
        end

      end

  end

end