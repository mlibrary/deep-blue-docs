# frozen_string_literal: true

module Deepblue

  module WorksControllerBehavior
    extend ActiveSupport::Concern
    #in umrdr
    #include Hyrax::Controller
    include Hyrax::WorksControllerBehavior
    include Deepblue::ControllerWorkflowEventBehavior
    include Deepblue::DoiControllerBehavior
    include Deepblue::IngestAppendScriptControllerBehavior

    WORKS_CONTROLLER_BEHAVIOR_VERBOSE = false

    class_methods do
      def curation_concern_type=(curation_concern_type)
        # begin monkey
        # load_and_authorize_resource class: curation_concern_type, instance_name: :curation_concern, except: [:show, :file_manager, :inspect_work, :manifest]
        # Note that the find_with_rescue(id) method specified catches Ldp::Gone exceptions and returns nil instead,
        # so if the curation_concern is nil, it's because it wasn't found or it was deleted
        load_and_authorize_resource class: curation_concern_type, find_by: :find_with_rescue, instance_name: :curation_concern, except: [:show, :file_manager, :inspect_work, :manifest]
        # end monkey

        # Load the fedora resource to get the etag.
        # No need to authorize for the file manager, because it does authorization via the presenter.
        load_resource class: curation_concern_type, instance_name: :curation_concern, only: :file_manager

        self._curation_concern_type = curation_concern_type
        # We don't want the breadcrumb action to occur until after the concern has
        # been loaded and authorized
        before_action :save_permissions, only: :update
      end
    end

    def after_create_response
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "curation_concern&.id=#{curation_concern&.id}",
                                             "@curation_concern=#{@curation_concern}",
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      respond_to do |wants|
        wants.html do
          # Calling `#t` in a controller context does not mark _html keys as html_safe
          flash[:notice] = view_context.t('hyrax.works.create.after_create_html', application_name: view_context.application_name)
          redirect_to [main_app, curation_concern]
        end
        wants.json do
          @presenter ||= show_presenter.new(curation_concern, current_ability, request)
          render :show, status: :created
        end
      end
    end

    def after_destroy_response(title)
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      respond_to do |wants|
        wants.html do
          if curation_concern.present?
            msg = "Deleted #{title}"
          else
            msg = "Not found #{title}"
          end
          redirect_to my_works_path, notice: msg
        end
        wants.json do
          if curation_concern.present?
            # works_render_json_response(response_type: :deleted, message: "Deleted #{curation_concern.id}") # this results in error 500 because of the response_type
            @presenter ||= show_presenter.new(curation_concern, current_ability, request)
            # render :delete, status: :delete # this results in an error 500 because of the status
            render :delete, status: :no_content # this works
          else
            # works_render_json_response( response_type: 410, message: "Already Deleted #{title}" )
            works_render_json_response( response_type: :not_found, message: "ID #{title}" )
          end
        end
      end
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
    end

    # render a json response for +response_type+
    def works_render_json_response(response_type: :success, message: nil, options: {})
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             "response_type=#{response_type}",
                                             "message=#{message}",
                                             "options=#{options}",
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      json_body = Hyrax::API.generate_response_body(response_type: response_type, message: message, options: options)
      render json: json_body, status: response_type
    end

    def after_update_response
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      if curation_concern.file_sets.present?
        return redirect_to main_app.copy_access_hyrax_permission_path(curation_concern)  if permissions_changed?
        return redirect_to main_app.confirm_hyrax_permission_path(curation_concern) if curation_concern.visibility_changed?
      end
      respond_to do |wants|
        wants.html { redirect_to [main_app, curation_concern], notice: "Work \"#{curation_concern}\" successfully updated." }
        wants.json { render :show, status: :ok, location: polymorphic_path([main_app, curation_concern]) }
      end
    end

    # override curation concerns, add form fields values
    def build_form
      super
      # Set up the multiple parameters for the date coverage attribute in the form
      cov_date = Date.edtf(@form.date_coverage)
      cov_params = Dataset::DateCoverageService.interval_to_params cov_date
      @form.merge_date_coverage_attributes! cov_params
    end

    def create
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      if actor.create(actor_environment)
        after_create_response
      else
        respond_to do |wants|
          wants.html do
            build_form
            render 'new', status: :unprocessable_entity
          end
          wants.json { render_json_response(response_type: :unprocessable_entity, options: { errors: curation_concern.errors }) }
        end
      end
    end

    def destroy
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      if curation_concern.present?
        title = curation_concern.to_s
      else
        title = params[:id]
      end
      if curation_concern.nil?
        after_destroy_response(title)
      elsif actor.destroy(env)
        env = Hyrax::Actors::Environment.new(curation_concern, current_ability, {})
        Hyrax.config.callback.run(:after_destroy, curation_concern&.id, current_user)
        after_destroy_response(title)
      end
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE # + caller_locations(1,40)
    end

    def new
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      # TODO: move these lines to the work form builder in Hyrax
      curation_concern.depositor = current_user.user_key
      curation_concern.admin_set_id = admin_set_id_for_new
      build_form
    end

    # Finds a solr document matching the id and sets @presenter
    # @raise CanCan::AccessDenied if the document is not found or the user doesn't have access to it.
    def show
      ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                             Deepblue::LoggingHelper.called_from,
                                             Deepblue::LoggingHelper.obj_class( 'class', self ),
                                             "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
      @user_collections = user_collections

      respond_to do |wants|
        ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                               Deepblue::LoggingHelper.called_from,
                                               Deepblue::LoggingHelper.obj_class( 'wants', wants ),
                                               "wants.format=#{wants.format}",
                                               "" ] if WORKS_CONTROLLER_BEHAVIOR_VERBOSE
        wants.html do
          presenter && parent_presenter
        end
        wants.json do
          # load and authorize @curation_concern manually because it's skipped for html
          # @curation_concern = _curation_concern_type.find(params[:id]) unless curation_concern
          @curation_concern = _curation_concern_type.find_with_rescue(params[:id]) unless curation_concern
          if @curation_concern
            presenter
            authorize! :show, @curation_concern
            render :show, status: :ok
          else
            works_render_json_response( response_type: :not_found, message: "ID #{params[:id]}" )
          end
        end
        additional_response_formats(wants)
        wants.ttl do
          render body: presenter.export_as_ttl, content_type: 'text/turtle'
        end
        wants.jsonld do
          render body: presenter.export_as_jsonld, content_type: 'application/ld+json'
        end
        wants.nt do
          render body: presenter.export_as_nt, content_type: 'application/n-triples'
        end
      end
    end


  end

end
