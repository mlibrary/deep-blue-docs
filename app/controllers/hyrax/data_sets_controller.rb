# frozen_string_literal: true

module Hyrax

  class DataSetsController < DeepblueController

    PARAMS_KEY = 'data_set'

    include Deepblue::WorksControllerBehavior

    self.curation_concern_type = ::DataSet
    self.show_presenter = Hyrax::DataSetPresenter

    before_action :assign_date_coverage,         only: %i[create update]
    before_action :assign_admin_set,             only: %i[create update]
    before_action :workflow_destroy,             only: [:destroy]
    before_action :provenance_log_update_before, only: [:update]
    before_action :visiblity_changed,            only: [:update]
    before_action :prepare_permissions,          only: [:show]

    after_action :workflow_create,               only: [:create]
    after_action :visibility_changed_update,     only: [:update]
    after_action :provenance_log_update_after,   only: [:update]
    after_action :reset_permissions,             only: [:show]

    protect_from_forgery with: :null_session,    only: [:display_provenance_log]
    protect_from_forgery with: :null_session,    only: [:globus_add_email]
    protect_from_forgery with: :null_session,    only: [:globus_download]
    protect_from_forgery with: :null_session,    only: [:globus_download_add_email]
    protect_from_forgery with: :null_session,    only: [:globus_download_notify_me]
    protect_from_forgery with: :null_session,    only: [:ingest_append_generate_script]
    protect_from_forgery with: :null_session,    only: [:ingest_append_prep]
    protect_from_forgery with: :null_session,    only: [:ingest_append_run_job]
    protect_from_forgery with: :null_session,    only: [:zip_download]

    attr_accessor :user_email_one, :user_email_two

    attr_accessor :provenance_log_entries

    # These methods (prepare_permissions, and reset_permissions) are used so that
    # when viewing a tombstoned work, and the user is not admin, the user 
    # will be able to see the metadata.
    def prepare_permissions
      if current_ability.admin?
      else
        # Need to add admin group to current_ability
        # or presenter will not be accessible.
        current_ability.user_groups << "admin"
        if presenter&.tombstone.present?
        else
          current_ability.user_groups.delete("admin")
        end
      end
    end

    def reset_permissions
      current_ability.user_groups.delete("admin")
    end


    ## box integration

    def box_create_dir_and_add_collaborator
      return nil unless DeepBlueDocs::Application.config.box_integration_enabled
      user_email = Deepblue::EmailHelper.user_email_from( current_user )
      BoxHelper.create_dir_and_add_collaborator( curation_concern.id, user_email: user_email )
    end

    def box_link
      return nil unless DeepBlueDocs::Application.config.box_integration_enabled
      BoxHelper.box_link( curation_concern.id )
    end

    def box_work_created
      box_create_dir_and_add_collaborator
    end

    ## end box integration

    ## date_coverage

    # Create EDTF::Interval from form parameters
    # Replace the date coverage parameter prior with serialization of EDTF::Interval
    def assign_date_coverage
      cov_interval = Dataset::DateCoverageService.params_to_interval params
      params[PARAMS_KEY]['date_coverage'] = cov_interval ? cov_interval.edtf : ""
    end

    def assign_admin_set
      admin_sets = Hyrax::AdminSetService.new(self).search_results(:deposit)
      admin_sets.each do |admin_set|
        if admin_set.id != "admin_set/default"
          params[PARAMS_KEY]['admin_set_id'] = admin_set.id
        end
      end
    end

    # end date_coverage

    ## Globus

    def globus_add_email
      if user_signed_in?
        user_email = Deepblue::EmailHelper.user_email_from( current_user )
        globus_copy_job( user_email: user_email, delay_per_file_seconds: 0 )
        flash_and_go_back globus_files_prepping_msg( user_email: user_email )
      elsif params[:user_email_one].present? || params[:user_email_two].present?
        user_email_one = params[:user_email_one].present? ? params[:user_email_one].strip : ''
        user_email_two = params[:user_email_two].present? ? params[:user_email_two].strip : ''
        # if user_email_one === user_email_two
        if user_email_one == user_email_two
          globus_copy_job( user_email: user_email_one, delay_per_file_seconds: 0 )
          flash_and_redirect_to_main_cc globus_files_prepping_msg( user_email: user_email_one )
        else
          flash.now[:error] = emails_did_not_match_msg( user_email_one, user_email_two )
          render 'globus_download_add_email_form'
        end
      else
        flash_and_redirect_to_main_cc globus_status_msg
      end
    end

    def globus_clean_download
      ::GlobusCleanJob.perform_later( curation_concern.id, clean_download: true )
      globus_ui_delay
      dirs = []
      dirs << ::GlobusJob.target_download_dir( curation_concern.id )
      dirs << ::GlobusJob.target_prep_dir( curation_concern.id, prefix: nil )
      dirs << ::GlobusJob.target_prep_tmp_dir( curation_concern.id, prefix: nil )
      flash_and_redirect_to_main_cc globus_clean_msg( dirs )
    end

    def globus_clean_prep
      ::GlobusCleanJob.perform_later( curation_concern.id, clean_download: false )
      globus_ui_delay
    end

    def globus_complete?
      ::GlobusJob.copy_complete? curation_concern.id
    end

    def globus_copy_job( user_email: nil,
                         delay_per_file_seconds: DeepBlueDocs::Application.config.globus_debug_delay_per_file_copy_job_seconds )

      ::GlobusCopyJob.perform_later( curation_concern.id,
                                     user_email: user_email,
                                     delay_per_file_seconds: delay_per_file_seconds )
      globus_ui_delay
    end

    def globus_download
      if globus_complete?
        flash_and_redirect_to_main_cc globus_files_available_here
      else
        user_email = Deepblue::EmailHelper.user_email_from( current_user, user_signed_in: user_signed_in? )
        msg = if globus_prepping?
                globus_files_prepping_msg( user_email: user_email )
              else
                globus_file_prep_started_msg( user_email: user_email )
              end
        if user_signed_in?
          globus_copy_job( user_email: user_email )
          flash_and_redirect_to_main_cc msg
        else
          globus_copy_job( user_email: nil )
          render 'globus_download_notify_me_form'
        end
      end
    end

    def globus_download_add_email
      if user_signed_in?
        globus_add_email
      else
        render 'globus_download_add_email_form'
      end
    end

    def globus_download_enabled?
      DeepBlueDocs::Application.config.globus_enabled
    end

    def globus_download_notify_me
      if user_signed_in?
        user_email = Deepblue::EmailHelper.user_email_from( current_user )
        globus_copy_job( user_email: user_email )
        flash_and_go_back globus_file_prep_started_msg( user_email: user_email )
      elsif params[:user_email_one].present? || params[:user_email_two].present?
        user_email_one = params[:user_email_one].present? ? params[:user_email_one].strip : ''
        user_email_two = params[:user_email_two].present? ? params[:user_email_two].strip : ''
        # if user_email_one === user_email_two
        if user_email_one == user_email_two
          globus_copy_job( user_email: user_email_one )
          flash_and_redirect_to_main_cc globus_file_prep_started_msg( user_email: user_email_one )
        else
          # flash_and_go_back emails_did_not_match_msg( user_email_one, user_email_two )
          flash.now[:error] = emails_did_not_match_msg( user_email_one, user_email_two )
          render 'globus_download_notify_me_form'
        end
      else
        globus_copy_job( user_email: nil )
        flash_and_redirect_to_main_cc globus_file_prep_started_msg
      end
    end

    def globus_enabled?
      DeepBlueDocs::Application.config.globus_enabled
    end

    def globus_last_error_msg
      ::GlobusJob.error_file_contents curation_concern.id
    end

    def globus_prepping?
      ::GlobusJob.files_prepping? curation_concern.id
    end

    def globus_ui_delay( delay_seconds: DeepBlueDocs::Application.config.globus_after_copy_job_ui_delay_seconds )
      sleep delay_seconds if delay_seconds.positive?
    end

    def globus_url
      ::GlobusJob.external_url curation_concern.id
    end

    ## end Globus

    ## Ingest begin
    #
    attr_reader :ingest_script

    def generate_depth( depth: )
      return "" if depth < 1
      return "  " * (2 * depth)
    end

    def generate_ingest_append_script
      # TODO
      script = []
      depth = 0
      script << "# title of script"
      script << "---"
      script << ":user:"
      depth += 1
      script << "#{generate_depth( depth: depth )}:visibility: #{ingest_visibility}"
      script << "#{generate_depth( depth: depth )}:email: '#{curation_concern.depositor}'"
      script << "#{generate_depth( depth: depth )}:ingester: '#{ingest_ingester}'"
      script << "#{generate_depth( depth: depth )}:source: DBDv2"
      script << "#{generate_depth( depth: depth )}:mode: append"
      script << "#{generate_depth( depth: depth )}:email_after: #{ingest_email_after}"
      # :email_after_add_log_msgs: true
      # :email_before: true
      # :email_ingester: true
      script << "#{generate_depth( depth: depth )}:email_ingester: #{ingest_email_ingester}"
      script << "#{generate_depth( depth: depth )}:email_depositor: #{ingest_email_depositor}"
      # :email_rest: false # set to true to add email notification to the following
      # :emails_rest:
      #     - test@umich.edu
      # - test2@umich.edu
      script << "#{generate_depth( depth: depth )}:works:"
      depth += 1
      script << "#{generate_depth( depth: depth )}:id: '#{curation_concern.id}'"
      script << "#{generate_depth( depth: depth )}:depositor: '#{curation_concern.depositor}'"
      # :owner: 'fritx@umich.edu'
      script << "#{generate_depth( depth: depth )}:filenames:"
      files = ingest_file_path_list.split("\n")
      depth += 1
      files.each do |f|
        f.strip!
        filename = ingest_file_path_name( f )
        msg = ingest_file_path_msg( f )
        script << "#{generate_depth( depth: depth )}- '#{filename}'#{msg}" if f.present?
      end
      depth -= 1
      script << "#{generate_depth( depth: depth )}:files:"
      depth += 1
      files.each do |f|
        script << "#{generate_depth( depth: depth )}- '#{f}'" if f.present?
      end
      script << "# end script"

      return script.join( "\n" )
    end

    def ingest_append_generate_script
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "params=#{params}",
                                             "" ]
      presenter.params = params
      presenter.ingest_ingester = ingest_ingester
      presenter.ingest_file_path_list = ingest_file_path_list
      presenter.ingest_base_directory = ingest_base_directory
      @ingest_script = generate_ingest_append_script
      presenter.ingest_script = @ingest_script
      render 'ingest_append_script_form'
    end

    def ingest_append_prep
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "params=#{params}",
                                             "" ]
      presenter.params = params
      presenter.ingest_ingester = ingest_ingester
      presenter.ingest_file_path_list = ingest_file_path_list
      presenter.ingest_base_directory = ingest_base_directory
      render 'ingest_append_prep_form'
    end

    def ingest_append_run_job
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "params=#{params}",
                                             "" ]
      # TODO
      msg = "Testing...append job will start here."
      redirect_to dashboard_works_path, notice: msg
    end

    def ingest_base_directory
      rv = params[:ingest_base_directory]
      return rv
    end

    def ingest_email_after
      "true"
    end

    def ingest_email_depositor
      "true"
    end

    def ingest_email_ingester
      "true"
    end

    def ingest_file_path_valid( path )
      # TODO - dev mode
      return false if path.blank?
      return false if path.include? ".."
      return true if path.to_s.start_with? "/deepbluedata-prep"
      return true if path.to_s.start_with? "/Volumes/ulib-dbd-prep"
      false
    end

    def ingest_file_path_list
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "params=#{params}",
                                             "params[:ingest_file_path_list]=#{params[:ingest_file_path_list]}",
                                             "" ]
      rv = params[:ingest_file_path_list]
      return params[:ingest_file_path_list] if rv.present?
      base_dir = ingest_base_directory&.strip
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "base_dir=#{base_dir}",
                                             "" ]
      return rv if base_dir.blank?
      starts_with_path = base_dir
      starts_with_path = starts_with_path + File::SEPARATOR unless starts_with_path.ends_with? File::SEPARATOR
      return rv unless ingest_file_path_valid( starts_with_path )
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "starts_with_path=#{starts_with_path}",
                                             "" ]
      files = Dir.glob( "#{starts_with_path}*" )
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "files=#{files}",
                                             "" ]
      path_list = []
      files.each do |f|
        ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                               Deepblue::LoggingHelper.called_from,
                                               "f=#{f}",
                                               "" ]
        if File.basename( f ) =~ /^\..*$/
          next
        end
        path_list << f
      end
      rv = path_list.join( "\n" )
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "rv=#{rv}",
                                             "" ]
      return rv
    end

    def ingest_file_path_msg( path )
      return " # is a directory" if Dir.exist?( path )
      return "" if File.file?( path )
      return " # file missing"
    end

    def ingest_file_path_name( path )
      rv = File.basename path
      return rv
    end

    def ingest_file_path_names( path_list )
      path_list = path_list.split("\n") if path_list.is_a? Array
      path_names = []
      path_list.each do |path|
        path_names << File.basename( path )
      end
      path_names
    end

    def ingest_ingester
      rv = params[:ingest_ingester]
      rv = current_user.user_key if rv.blank?
      rv
    end

    def ingest_visibility
      curation_concern.visibility.to_s
    end

    ## Ingest end

    ## Provenance log

    def provenance_log_update_after
      curation_concern.provenance_log_update_after( current_user: current_user,
                                                    # event_note: 'DataSetsController.provenance_log_update_after',
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

    ## Tombstone

    def tombstone
      epitaph = params[:tombstone]
      success = curation_concern.entomb!( epitaph, current_user )
      msg = if success
              MsgHelper.t( 'data_set.tombstone_notice', title: curation_concern.title.first.to_s, reason: epitaph.to_s )
              curation_concern.globus_clean_download if curation_concern.respond_to? :globus_clean_download
            else
              "#{curation_concern.title.first} is already tombstoned."
            end
      redirect_to dashboard_works_path, notice: msg
    end

    def tombstone_enabled?
      true
    end

    ## End Tombstone

    ## visibility / publish

    def visiblity_changed
      # ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
      #                                        Deepblue::LoggingHelper.called_from,
      #                                        Deepblue::LoggingHelper.obj_class( 'class', self ),
      #                                        "" ]
      if visibility_to_private?
        mark_as_set_to_private
      elsif visibility_to_public?
        mark_as_set_to_public
      end
    end

    def visibility_changed_update
      # ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
      #                                        Deepblue::LoggingHelper.called_from,
      #                                        Deepblue::LoggingHelper.obj_class( 'class', self ),
      #                                        "" ]
      if curation_concern.private? && @visibility_changed_to_private
       workflow_unpublish
      elsif curation_concern.public? && @visibility_changed_to_public
        workflow_publish
      end
    end

    def visibility_to_private?
      # ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
      #                                        Deepblue::LoggingHelper.called_from,
      #                                        Deepblue::LoggingHelper.obj_class( 'class', self ),
      #                                        "" ]
      return false if curation_concern.private?
      params[PARAMS_KEY]['visibility'] == Hydra::AccessControls::AccessRight::VISIBILITY_TEXT_VALUE_PRIVATE
    end

    def visibility_to_public?
      # ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
      #                                        Deepblue::LoggingHelper.called_from,
      #                                        Deepblue::LoggingHelper.obj_class( 'class', self ),
      #                                        "" ]
      return false if curation_concern.public?
      params[PARAMS_KEY]['visibility'] == Hydra::AccessControls::AccessRight::VISIBILITY_TEXT_VALUE_PUBLIC
    end

    def mark_as_set_to_private
      @visibility_changed_to_public = false
      @visibility_changed_to_private = true
    end

    def mark_as_set_to_public
      @visibility_changed_to_public = true
      @visibility_changed_to_private = false
    end

    ## end visibility / publish

    ## begin zip download operations

    def zip_download
      require 'zip'
      require 'tempfile'

      tmp_dir = ENV['TMPDIR'] || "/tmp"
      tmp_dir = Pathname.new tmp_dir
      # Deepblue::LoggingHelper.debug "Download Zip begin tmp_dir #{tmp_dir}"
      Deepblue::LoggingHelper.bold_debug [ "zip_download begin", "tmp_dir=#{tmp_dir}" ]
      target_dir = target_dir_name_id( tmp_dir, curation_concern.id )
      # Deepblue::LoggingHelper.debug "Download Zip begin copy to folder #{target_dir}"
      Deepblue::LoggingHelper.bold_debug [ "zip_download", "target_dir=#{target_dir}" ]
      Dir.mkdir( target_dir ) unless Dir.exist?( target_dir )
      target_zipfile = target_dir_name_id( target_dir, curation_concern.id, ".zip" )
      # Deepblue::LoggingHelper.debug "Download Zip begin copy to target_zipfile #{target_zipfile}"
      Deepblue::LoggingHelper.bold_debug [ "zip_download", "target_zipfile=#{target_zipfile}" ]
      File.delete target_zipfile if File.exist? target_zipfile
      # clean the zip directory if necessary, since the zip structure is currently flat, only
      # have to clean files in the target folder
      files = Dir.glob( (target_dir.join '*').to_s)
      Deepblue::LoggingHelper.bold_debug files, label: "zip_download files to delete:"
      files.each do |file|
        File.delete file if File.exist? file
      end
      Deepblue::LoggingHelper.debug "Download Zip begin copy to folder #{target_dir}"
      Deepblue::LoggingHelper.bold_debug [ "zip_download", "begin copy target_dir=#{target_dir}" ]
      Zip::File.open(target_zipfile.to_s, Zip::File::CREATE ) do |zipfile|
        metadata_filename = curation_concern.metadata_report( dir: target_dir )
        zipfile.add( metadata_filename.basename, metadata_filename )
        export_file_sets_to( target_dir: target_dir, log_prefix: "Zip: " ) do |target_file_name, target_file|
          zipfile.add( target_file_name, target_file )
        end
      end
      # Deepblue::LoggingHelper.debug "Download Zip copy complete to folder #{target_dir}"
      Deepblue::LoggingHelper.bold_debug [ "zip_download", "download complete target_dir=#{target_dir}" ]
      send_file target_zipfile.to_s
    end

    def zip_download_enabled?
      true
    end

    # end zip download operations

    # # Create EDTF::Interval from form parameters
    # # Replace the date coverage parameter prior with serialization of EDTF::Interval
    # def assign_date_coverage
    #   ##cov_interval = Umrdr::DateCoverageService.params_to_interval params
    #   ##params['generic_work']['date_coverage'] = cov_interval ? [cov_interval.edtf] : []
    # end
    #
    # def check_recent_uploads
    #   if params[:uploads_since]
    #     begin
    #       @recent_uploads = [];
    #       uploads_since = Time.at(params[:uploads_since].to_i / 1000.0)
    #       presenter.file_set_presenters.reverse_each do |file_set|
    #         date_uploaded = get_date_uploaded_from_solr(file_set)
    #         if date_uploaded.nil? or date_uploaded < uploads_since
    #           break
    #         end
    #         @recent_uploads.unshift file_set
    #       end
    #     rescue Exception => e
    #       Rails.logger.info "Something happened in check_recent_uploads: #{params[:uploads_since]} : #{e.message}"
    #     end
    #   end
    # end

    protected

      def emails_did_not_match_msg( _user_email_one, _user_email_two )
        "Emails did not match" # + ": '#{user_email_one}' != '#{user_email_two}'"
      end

      def export_file_sets_to( target_dir:,
                               log_prefix: "",
                               do_export_predicate: ->(_target_file_name, _target_file) { true },
                               quiet: false,
                               &block )
        file_sets = curation_concern.file_sets
        Deepblue::ExportFilesHelper.export_file_sets( target_dir: target_dir,
                                                      file_sets: file_sets,
                                                      log_prefix: log_prefix,
                                                      do_export_predicate: do_export_predicate,
                                                      quiet: quiet,
                                                      &block )
      end

      def flash_and_go_back( msg )
        Deepblue::LoggingHelper.debug msg
        redirect_to :back, notice: msg
      end

      def flash_error_and_go_back( msg )
        Deepblue::LoggingHelper.debug msg
        redirect_to :back, error: msg
      end

      def flash_and_redirect_to_main_cc( msg )
        Deepblue::LoggingHelper.debug msg
        redirect_to [main_app, curation_concern], notice: msg
      end

      def globus_clean_msg( dir )
        dirs = dir.join( MsgHelper.t( 'data_set.globus_clean_join_html' ) )
        rv = MsgHelper.t( 'data_set.globus_clean', dirs: dirs )
        return rv
      end

      def globus_file_prep_started_msg( user_email: nil )
        MsgHelper.t( 'data_set.globus_file_prep_started',
                     when_available: globus_files_when_available( user_email: user_email ) )
      end

      def globus_files_prepping_msg( user_email: nil )
        MsgHelper.t( 'data_set.globus_files_prepping',
                     when_available: globus_files_when_available( user_email: user_email ) )
      end

      def globus_files_when_available( user_email: nil )
        if user_email.nil?
          MsgHelper.t( 'data_set.globus_files_when_available' )
        else
          MsgHelper.t( 'data_set.globus_files_when_available_email', user_email: user_email )
        end
      end

      def globus_files_available_here
        MsgHelper.t( 'data_set.globus_files_available_here', globus_url: globus_url.to_s )
      end

      def globus_status_msg( user_email: nil )
        msg = if globus_complete?
                globus_files_available_here
              elsif globus_prepping?
                globus_files_prepping_msg( user_email: user_email )
              else
                globus_file_prep_started_msg( user_email: user_email )
              end
        msg
      end

      def show_presenter
        Hyrax::DataSetPresenter
      end

    private

      def get_date_uploaded_from_solr(file_set)
        field = file_set.solr_document[Solrizer.solr_name('date_uploaded', :stored_sortable, type: :date)]
        return if field.blank?
        begin
          Time.parse(field)
        rescue
          Rails.logger.info "Unable to parse date: #{field.first.inspect} for #{self['id']}"
        end
      end

      def target_dir_name_id( dir, id, ext = '' )
        dir.join "#{DeepBlueDocs::Application.config.base_file_name}#{id}#{ext}"
      end

  end

end
