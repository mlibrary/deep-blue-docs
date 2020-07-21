# frozen_string_literal: true

require File.join( Gem::Specification.find_by_name("hyrax").full_gem_path, "app/controllers/hyrax/file_sets_controller.rb" )

module Hyrax

  # monkey patch FileSetsController
  class FileSetsController < ApplicationController

    FILE_SETS_CONTROLLER_DEBUG_VERBOSE = ::DeepBlueDocs::Application.config.file_sets_controller_debug_verbose

    include Deepblue::DoiControllerBehavior

    PARAMS_KEY = 'file_set'
    self.show_presenter = Hyrax::DsFileSetPresenter

    alias_method :monkey_attempt_update, :attempt_update
    # alias_method :monkey_update_metadata, :update_metadata

    before_action :provenance_log_destroy,       only: [:destroy]
    before_action :provenance_log_update_before, only: [:update]

    after_action :provenance_log_create,         only: [:create]
    after_action :provenance_log_update_after,   only: [:update]

    protect_from_forgery with: :null_session,    only: [:file_contents]
    protect_from_forgery with: :null_session,    only: [:display_provenance_log]

    def file_contents
      Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                           Deepblue::LoggingHelper.called_from,
                                           "file_set.id=#{file_set.id}",
                                           "file_set.mime_type=#{file_set.mime_type}",
                                           "file_set.original_file.size=#{file_set.original_file.size}",
                                           "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
      allowed = display_file_contents_allowed?
      Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                           Deepblue::LoggingHelper.called_from,
                                           "file_set.id=#{file_set.id}",
                                           "file_set.mime_type=#{file_set.mime_type}",
                                           "file_set.original_file.size=#{file_set.original_file.size}",
                                           "allowed=#{allowed}",
                                           "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
      redirect_to [main_app, curation_concern] unless allowed
      presenter # make sure presenter is created
      render action: 'show_contents'
    end

    ## User access begin

    def current_user_can_edit?
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "current_user&.email=#{current_user&.email}",
                                             "curation_concern&.parent.edit_users=#{curation_concern&.parent.edit_users}",
                                             "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
      return unless current_user.present?
      return unless curation_concern.parent.present?
      curation_concern.parent.edit_users.include? current_user.email
    end

    def current_user_can_read?
      ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                             ::Deepblue::LoggingHelper.called_from,
                                             "current_user&.email=#{current_user&.email}",
                                             "curation_concern&.parent.read_users=#{curation_concern&.parent.read_users}",
                                             "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
      return unless current_user.present?
      return unless curation_concern.parent.present?
      curation_concern.parent.read_users.include? current_user.email
    end

    ## User access end

    def display_file_contents_allowed?
      Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                           Deepblue::LoggingHelper.called_from,
                                           "file_set.id=#{file_set.id}",
                                           "file_set.mime_type=#{file_set.mime_type}",
                                           "file_set.original_file.size=#{file_set.original_file.size}",
                                           "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
      return false unless ::DeepBlueDocs::Application.config.file_sets_contents_view_allow
      return false unless ( current_ability.admin? ) # || current_ability.can?(:read, id) )
      return false unless ::DeepBlueDocs::Application.config.file_sets_contents_view_mime_types.include?( file_set.mime_type )
      return false if file_set.original_file.size.blank?
      return false if file_set.original_file.size > ::DeepBlueDocs::Application.config.file_sets_contents_view_max_size
      return true
    end

    ## Provenance log

    def provenance_log_create
      curation_concern.provenance_create( current_user: current_user, event_note: 'FileSetsController' )
    end

    def provenance_log_destroy
      curation_concern.provenance_destroy( current_user: current_user, event_note: 'FileSetsController' )
      if curation_concern.parent.present?
        parent = curation_concern.parent
        Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "provenance_child_remove",
                                             "parent.id=#{parent.id}",
                                             "child_id=#{curation_concern.id}",
                                             "child_title=#{curation_concern.title}",
                                             "event_note=FileSetsController",
                                             "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
        return unless parent.respond_to? :provenance_child_add
        parent.provenance_child_remove( current_user: current_user,
                                        child_id: curation_concern.id,
                                        child_title: curation_concern.title,
                                        event_note: "FileSetsController" )
      end
    end

    def provenance_log_update_after
      curation_concern.provenance_log_update_after( current_user: current_user,
                                                    # event_note: 'FileSetsController.provenance_log_update_after',
                                                    update_attr_key_values: @update_attr_key_values )
    end

    def provenance_log_update_before
      @update_attr_key_values = curation_concern.provenance_log_update_before( form_params: params[PARAMS_KEY].dup )
    end

    ## end Provenance log

    ## display provenance log

    def display_provenance_log
      # load provenance log for this work
      file_path = Deepblue::ProvenancePath.path_for_reference( curation_concern.id )
      Deepblue::LoggingHelper.bold_debug [ "DataSetsController", "display_provenance_log", file_path ]
      Deepblue::ProvenanceLogService.entries( curation_concern.id, refresh: true )
      # continue on to normal display
      redirect_to [main_app, curation_concern]
    end

    def display_provenance_log_enabled?
      true
    end

    def provenance_log_entries_present?
      provenance_log_entries.present?
    end

    ## end display provenance log

    protected

      def attempt_update
        # Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
        #                                      Deepblue::LoggingHelper.called_from,
        #                                      "params=#{params}",
        #                                      "current_user=#{current_user}",
        #                                      Deepblue::LoggingHelper.obj_class( "actor", actor ) ]
        if wants_to_revert?
          Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                               Deepblue::LoggingHelper.called_from,
                                               "params=#{params}",
                                               "current_user=#{current_user}",
                                               Deepblue::LoggingHelper.obj_class( "actor", actor ),
                                               "wants to revert" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
          actor.revert_content(params[:revision])
        elsif params.key?(:file_set)
          if params[:file_set].key?(:files)
            Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                                 Deepblue::LoggingHelper.called_from,
                                                 "params=#{params}",
                                                 "current_user=#{current_user}",
                                                 Deepblue::LoggingHelper.obj_class( "actor", actor ),
                                                 "actor.update_content" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
            actor.update_content(params[:file_set][:files].first)
          else
            Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                                 Deepblue::LoggingHelper.called_from,
                                                 "params=#{params}",
                                                 "current_user=#{current_user}",
                                                 "update_metadata" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
            update_metadata
          end
        elsif params.key?(:files_files) # version file already uploaded with ref id in :files_files array
          Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                               Deepblue::LoggingHelper.called_from,
                                               "params=#{params}",
                                               "current_user=#{current_user}",
                                               Deepblue::LoggingHelper.obj_class( "actor", actor ),
                                               "actor.update_content" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
          uploaded_files = Array(Hyrax::UploadedFile.find(params[:files_files]))
          actor.update_content(uploaded_files.first)
          update_metadata
        end
      end

      def presenter
        @presenter ||= begin
          curation_concern = search_result_document( params )
          show_presenter.new( curation_concern, current_ability, request )
        end
      end

      def show_presenter
        Hyrax::DsFileSetPresenter
      end

      def search_result_document( search_params )
        _, document_list = search_results( search_params )
        return document_list.first unless document_list.empty?
        # document_not_found!
        raise CanCan::AccessDenied
      rescue Blacklight::Exceptions::RecordNotFound => e
        ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                               ::Deepblue::LoggingHelper.called_from,
                                               "e=#{e}",
                                               "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
        begin
          # check with Fedora to see if the requested id was deleted
          id = params[:id]
          ActiveFedora::Base.find( id )
        rescue Ldp::Gone => gone
          # it was deleted
          ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                                 ::Deepblue::LoggingHelper.called_from,
                                                 "gone=#{gone.class} #{gone.message} at #{gone.backtrace[0]}",
                                                 "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
          # okay, since this looks like a deleted curation concern, we can check the provenance log
          # if admin, redirect to the provenance log controller
          if current_ability.admin?
            url = Rails.application.routes.url_helpers.url_for( only_path: true,
                                                                action: 'show',
                                                                controller: 'provenance_log',
                                                                id: id )
            return redirect_to( url, error: "#{id} was deleted." )
          end
        rescue ActiveFedora::ObjectNotFoundError => e2
          # nope, never existed
          ::Deepblue::LoggingHelper.bold_debug [ ::Deepblue::LoggingHelper.here,
                                                 ::Deepblue::LoggingHelper.called_from,
                                                 "e2=#{e2.class} #{e2.message} at #{e2.backtrace[0]}",
                                                 "" ] if FILE_SETS_CONTROLLER_DEBUG_VERBOSE
        end
        raise CanCan::AccessDenied
      end

  end

end
