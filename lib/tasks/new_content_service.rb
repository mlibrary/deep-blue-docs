# frozen_string_literal: true

require 'hydra/file_characterization'
require_relative './task_logger'

Hydra::FileCharacterization::Characterizers::Fits.tool_path = `which fits || which fits.sh`.strip

module Deepblue

  class NewContentService

    SOURCE_DBDv1 = 'DBDv1' # rubocop:disable Style/ConstantName
    SOURCE_DBDv2 = 'DBDv2' # rubocop:disable Style/ConstantName
    MODE_APPEND = 'append'
    MODE_BUILD = 'build'
    MODE_MIGRATE = 'migrate'
    MODE_UPDATE = 'update' # TODO

    class RestrictedVocabularyError < RuntimeError
    end

    class TaskConfigError < RuntimeError
    end

    class UserNotFoundError < RuntimeError
    end

    class VisibilityError < RuntimeError
    end

    class WorkNotFoundError < RuntimeError
    end

    attr_reader :base_path, :cfg_hash, :config, :ingest_id, :ingester, :ingest_timestamp, :mode, :path_to_yaml_file, :user

    def initialize( path_to_yaml_file:, cfg_hash:, base_path:, args: )
      initialize_with_msg( args: args,
                           path_to_yaml_file: path_to_yaml_file,
                           cfg_hash: cfg_hash,
                           base_path: base_path )
    end

    def run
      validate_config
      build_repo_contents
    rescue RestrictedVocabularyError => e
      logger.error e.message.to_s
    rescue TaskConfigError => e
      logger.error e.message.to_s
    rescue UserNotFoundError => e
      logger.error e.message.to_s
    rescue VisibilityError => e
      logger.error e.message.to_s
    rescue WorkNotFoundError => e
      logger.error e.message.to_s
    rescue Exception => e # rubocop:disable Lint/RescueException
      logger.error "#{e.class}: #{e.message} at #{e.backtrace[0]}"
    end

    protected

      def add_file_set_to_work( work:, file_set: )
        return if file_set.parent.present? && work.id == file_set.parent_id
        work.ordered_members << file_set
        log_provenance_add_child( parent: work, child: file_set )
        work.total_file_size_add_file_set file_set
        work.representative = file_set if work.representative_id.blank?
        work.thumbnail = file_set if work.thumbnail_id.blank?
      end

      def add_file_sets_to_work( work_hash:, work: )
        file_set_ids = work_hash[:file_set_ids]
        return add_file_sets_to_work_from_file_set_ids( work_hash: work_hash, work: work ) if file_set_ids.present?
        return add_file_sets_to_work_from_files( work_hash: work_hash, work: work )
      end

      def add_file_sets_to_work_from_file_set_ids( work_hash:, work: )
        file_set_ids = work_hash[:file_set_ids]
        file_set_ids.each do |file_set_id|
          file_set_key = "f_#{file_set_id}"
          file_set_hash = work_hash[file_set_key.to_sym]
          file_set = build_file_set_from_hash( id: file_set_id, file_set_hash: file_set_hash, parent: work )
          add_file_set_to_work( work: work, file_set: file_set )
        end
        work.save!
        work.reload
        return work
      end

      def add_file_sets_to_work_from_files( work_hash:, work: )
        files = work_hash[:files]
        return work if files.blank?
        file_ids = work_hash[:file_ids]
        file_ids = [] if file_ids.nil?
        filenames = work_hash[:filenames]
        filenames = [] if filenames.nil?
        paths_and_names = files.zip( filenames, file_ids )
        paths_and_names.each do |fp|
          fs = build_file_set( id: nil, path: fp[0], file_set_vis: work.visibility, filename: fp[1], file_ids: fp[2] )
          add_file_set_to_work( work: work, file_set: fs )
        end
        work.save!
        work.reload
        return work
      end

      def add_works_to_collection( collection_hash:, collection: )
        # puts "collection_hash=#{collection_hash}"
        work_ids = works_from_hash( hash: collection_hash )
        work_ids[0].each do |work_id|
          # puts "work_id=#{work_id}"
          work_hash = works_from_id( hash: collection_hash, work_id: work_id )
          # puts "work_hash=#{work_hash}"
          work = build_or_find_work( work_hash: work_hash, parent: collection )
          next if work.member_of_collection_ids.include? collection.id
          work.member_of_collections << collection
          log_provenance_add_child( parent: collection, child: work )
          work.save!
        end
        collection.save!
        collection.reload
        return collection
      end

      def build_admin_set( hash: )
        admin_set_id = hash[:admin_set_id]
        return default_admin_set if admin_set_id.blank?
        return default_admin_set if AdminSet.default_set? admin_set_id
        begin
          admin_set = AdminSet.find( admin_set_id )
        rescue ActiveFedora::ObjectNotFoundError
          # TODO: Log this
          admin_set = default_admin_set
        end
        admin_set
      end

      def build_collection( id:, collection_hash: )
        if MODE_APPEND == mode && id.present?
          collection = find_collection_using_prior_id( prior_id: id )
          log_msg( "#{mode}: found collection with prior id: #{id} title: #{collection.title.first}" ) if collection.present?
          return collection if collection.present?
        end
        if MODE_MIGRATE == mode && id.present?
          collection = find_collection_using_id( id: id )
          log_msg( "#{mode}: found collection with id: #{id} title: #{collection.title.first}" ) if collection.present?
          return collection if collection.present?
        end
        title = Array( collection_hash[:title] )
        creator = Array( collection_hash[:creator] )
        curation_notes_admin = Array( collection_hash[:curation_notes_admin] )
        curation_notes_user = Array( collection_hash[:curation_notes_user] )
        description = Array( collection_hash[:description] )
        prior_identifier = build_prior_identifier( hash: collection_hash, id: id )
        subject_discipline = build_subject_discipline( hash: collection_hash )
        date_uploaded = build_date( hash: collection_hash, key: :date_uploaded )
        date_modified = build_date( hash: collection_hash, key: :date_modified )
        date_created = build_date( hash: collection_hash, key: :date_created )
        resource_type = Array( collection_hash[:resource_type] || 'Collection' )
        language = Array( collection_hash[:language] )
        keyword = Array( collection_hash[:keyword] )
        referenced_by = build_referenced_by( hash: collection_hash )
        id_new = MODE_MIGRATE == mode ? id : nil
        collection = new_collection( creator: creator,
                                     curation_notes_admin: curation_notes_admin,
                                     curation_notes_user: curation_notes_user,
                                     date_created: date_created,
                                     date_modified: date_modified,
                                     date_uploaded: date_uploaded,
                                     description: description,
                                     id: id_new,
                                     keyword: keyword,
                                     language: language,
                                     prior_identifier: prior_identifier,
                                     referenced_by: referenced_by,
                                     resource_type: resource_type,
                                     subject_discipline: subject_discipline,
                                     title: title )
        collection.collection_type = build_collection_type( hash: collection_hash )
        collection.apply_depositor_metadata( user_key )
        collection.visibility = visibility_from_hash( hash: collection_hash )
        collection.save!
        collection.reload
        log_provenance_ingest( curation_concern: collection )
        return collection
      end

      def build_collection_type( hash: )
        return Hyrax::CollectionType.find_or_create_default_collection_type if 'DBDv1' == source
        collection_type = hash[:collection_type]
        collection_type = Hyrax::CollectionType.find_by( machine_id: collection_type ) if collection_type.present?
        return collection_type if collection_type.present?
        collection_type_gid = hash[:collection_type_gid]
        collection_type = Hyrax::CollectionType.find_by_gid( collection_type_gid ) if collection_type_gid.present?
        return collection_type if collection_type.present?
        Hyrax::CollectionType.find_or_create_default_collection_type
      end

      def build_collections
        return unless collections
        collections.each { |collection_hash| build_or_find_collection( collection_hash: collection_hash ) }
      end

      def build_date( hash:, key: )
        rv = hash[key]
        return rv unless rv.to_s.empty?
        DateTime.now.to_s
      end

      def build_file_set( id:, path:, file_set_vis:, filename: nil, file_ids: nil )
        # puts "id=#{id} path=#{path} filename=#{filename} file_ids=#{file_ids}"
        fname = filename || File.basename( path )
        build_file_set_new( id: id, path: path, original_name: fname )
        file_set.title = Array( fname )
        file_set.label = fname
        now = DateTime.now.new_offset( 0 )
        file_set.date_uploaded = now
        file_set.visibility = file_set_vis
        file_set.prior_identifier = file_ids if file_ids.present?
        file_set.save!
        return build_file_set_ingest( file_set: file_set, path: path, checksum_algorithm: nil, checksum_value: nil )
      end

      def build_file_set_from_hash( id:, file_set_hash:, parent: )
        if MODE_APPEND == mode && id.present?
          file_set = find_file_set_using_prior_id( prior_id: id, parent: parent )
          log_msg( "#{mode}: found file_set with prior id: #{id} title: #{file_set.title.first}" ) if file_set.present?
          return file_set if file_set.present?
        end
        if MODE_MIGRATE == mode && id.present?
          file_set = find_file_set_using_id( id: id )
          log_msg( "#{mode}: found file_set with id: #{id} title: #{file_set.title.first}" ) if file_set.present?
          return file_set if file_set.present?
        end
        # puts "id=#{id} path=#{path} filename=#{filename} file_ids=#{file_ids}"

        path = file_set_hash[:file_path]
        original_name = file_set_hash[:original_name]
        file_set = build_file_set_new( id: id, path: path, original_name: original_name )

        title = Array( file_set_hash[:title] )
        label = file_set_hash[:label]
        curation_notes_admin = Array( file_set_hash[:curation_notes_admin] )
        curation_notes_user = Array( file_set_hash[:curation_notes_user] )
        checksum_algorithm = file_set_hash[:checksum_algorithm]
        checksum_value = file_set_hash[:checksum_value]
        date_uploaded = build_date( hash: file_set_hash, key: :date_uploaded )
        date_modified = build_date( hash: file_set_hash, key: :date_modified )
        date_created = Array( build_date( hash: file_set_hash, key: :date_created ) )
        prior_identifier = build_prior_identifier( hash: file_set_hash, id: id )
        visibility = visibility_from_hash( hash: file_set_hash )

        update_cc_attribute(curation_concern: file_set, attribute: :title, value: title )
        update_cc_attribute(curation_concern: file_set, attribute: :curation_notes_admin, value: curation_notes_admin )
        update_cc_attribute(curation_concern: file_set, attribute: :curation_notes_user, value: curation_notes_user )
        file_set.label = label
        file_set.date_uploaded = date_uploaded
        file_set.date_modified = date_modified
        file_set.date_created = date_created
        update_cc_attribute(curation_concern: file_set, attribute: :prior_identifier, value: prior_identifier )
        update_visibility( curation_concern: file_set, visibility: visibility )
        file_set.save!

        return build_file_set_ingest( file_set: file_set,
                                      path: path,
                                      checksum_algorithm: checksum_algorithm,
                                      checksum_value: checksum_value )
      end

      def build_file_set_ingest( file_set:, path:, checksum_algorithm:, checksum_value: )
        log_object file_set
        repository_file_id = nil
        IngestHelper.characterize( file_set,
                                   repository_file_id,
                                   path,
                                   delete_input_file: false,
                                   continue_job_chain: false,
                                   current_user: user,
                                   ingest_id: ingest_id,
                                   ingester: ingester,
                                   ingest_timestamp: ingest_timestamp )
        IngestHelper.create_derivatives( file_set,
                                         repository_file_id,
                                         path,
                                         delete_input_file: false,
                                         current_user: user,
                                         ingest_id: ingest_id,
                                         ingester: ingester,
                                         ingest_timestamp: ingest_timestamp )
        log_provenance_ingest( curation_concern: file_set )
        if checksum_algorithm.present? && checksum_value.present?
          # TODO
          # TODO add provenance logging of checksum
          # TODO
          checksum = file_set_checksum( file_set: file_set )
          log_msg( "#{mode}: file checksum is nil" ) if checksum.blank?
          if checksum.present? && checksum.algorithm == checksum_algorithm
            if checksum.value == checksum_value
              log_msg( "#{mode}: checksum succeeded: #{checksum_value}" )
            else
              log_msg( "#{mode}: WARNING checksum failed: #{checksum.value} vs #{checksum_value}" )
            end
          else
            log_msg( "#{mode}: incompatible checksum algorithms: #{checksum.algorithm} vs #{checksum_algorithm}" )
          end
        end
        log_msg( "#{mode}: finished: #{path}" )
        return file_set
      end

      def build_file_set_new( id:, path:, original_name: )
        log_msg( "#{mode}: processing: #{path}" )
        file = File.open( path )
        # fix so that filename comes from the name of the file and not the hash
        file.define_singleton_method( :original_name ) do
          original_name
        end
        id_new = MODE_MIGRATE == mode ? id : nil
        file_set = new_file_set( id: id_new )
        file_set.apply_depositor_metadata( user_key )
        Hydra::Works::UploadFileToFileSet.call( file_set, file )
        return file_set
      end

      def build_fundedby( hash: )
        rv = Array( hash[:fundedby] )
        return rv
      end

      def build_or_find_collection( collection_hash: )
        # puts "build_or_find_collection( collection_hash: #{ActiveSupport::JSON.encode( collection_hash )} )"
        return if collection_hash.blank?
        id = collection_hash[:id]
        collection = build_collection( id: id, collection_hash: collection_hash ) if collection.nil?
        log_object collection if collection.present?
        add_works_to_collection( collection_hash: collection_hash, collection: collection )
        collection.save!
        return collection
      end

      def build_or_find_work( work_hash:, parent: )
        # puts "build_or_find_work( work_hash: #{work_hash} )"
        return nil if work_hash.blank?
        id = work_hash[:id]
        work = build_work( id: id, work_hash: work_hash, parent: parent ) if work.nil?
        log_object work if work.present?
        add_file_sets_to_work( work_hash: work_hash, work: work )
        return work
      end

      def build_prior_identifier( hash:, id: )
        if 'DBDv1' == source
          if MODE_MIGRATE == mode
            []
          else
            Array( id )
          end
        else
          arr = Array( hash[:prior_identifier] )
          return arr if MODE_MIGRATE == mode
          arr << id if id.present?
        end
      end

      def build_referenced_by( hash: )
        if 'DBDv1' == source
          Array( hash[:isReferencedBy] )
        else
          hash[:referenced_by]
        end
      end

      def build_rights_liscense( hash: )
        rv = if 'DBDv1' == source
               hash[:rights]
             else
               hash[:rights_license]
             end
        rv = rv[0] if rv.respond_to?( '[]' )
        return rv
      end

      def build_repo_contents
        # override with something interesting
      end

      def build_subject_discipline( hash: )
        if 'DBDv1' == source
          Array( hash[:subject] )
        else
          Array( hash[:subject_discipline] )
        end
      end

      def build_work( id:, work_hash:, parent: )
        if MODE_APPEND == mode && id.present?
          work = find_data_set_using_prior_id( prior_id: id, parent: parent )
          log_msg( "#{mode}: found work with prior id: #{id} title: #{work.title.first}" ) if work.present?
          return work if work.present?
        end
        if MODE_MIGRATE == mode && id.present?
          work = find_data_set_using_id( id: id )
          log_msg( "#{mode}: found work with id: #{id} title: #{work.title.first}" ) if work.present?
          return work if work.present?
        end
        title = Array( work_hash[:title] )
        creator = Array( work_hash[:creator] )
        curation_notes_admin = Array( work_hash[:curation_notes_admin] )
        curation_notes_user = Array( work_hash[:curation_notes_user] )
        authoremail = work_hash[:authoremail]
        rights_license = build_rights_liscense( hash: work_hash )
        rights_license_other = work_hash[:rights_license_other]
        description = Array( work_hash[:description] )
        methodology = work_hash[:methodology] || "No Methodology Available"
        prior_identifier = build_prior_identifier( hash: work_hash, id: id )
        subject_discipline = build_subject_discipline( hash: work_hash )
        contributor = Array( work_hash[:contributor] )
        date_uploaded = build_date( hash: work_hash, key: :date_uploaded )
        date_modified = build_date( hash: work_hash, key: :date_modified )
        date_created = build_date( hash: work_hash, key: :date_created )
        date_coverage = work_hash[:date_coverage]
        resource_type = Array( work_hash[:resource_type] || 'Dataset' )
        language = Array( work_hash[:language] )
        keyword = Array( work_hash[:keyword] )
        referenced_by = build_referenced_by( hash: work_hash )
        fundedby = build_fundedby( hash: work_hash )
        fundedby_other = work_hash[:fundedby_other]
        grantnumber = work_hash[:grantnumber]
        id_new = MODE_MIGRATE == mode ? id : nil
        work = new_data_set( authoremail: authoremail,
                             contributor: contributor,
                             creator: creator,
                             curation_notes_admin: curation_notes_admin,
                             curation_notes_user: curation_notes_user,
                             date_coverage: date_coverage,
                             date_created: date_created,
                             date_modified: date_modified,
                             date_uploaded: date_uploaded,
                             description: description,
                             fundedby: fundedby,
                             fundedby_other: fundedby_other,
                             grantnumber: grantnumber,
                             id: id_new,
                             keyword: keyword,
                             language: language,
                             methodology: methodology,
                             prior_identifier: prior_identifier,
                             referenced_by: referenced_by,
                             resource_type: resource_type,
                             rights_license: rights_license,
                             rights_license_other: rights_license_other,
                             subject_discipline: subject_discipline,
                             title: title )

        work.apply_depositor_metadata( user_key )
        work.owner = user_key
        work.visibility = visibility_from_hash( hash: work_hash )
        admin_set = build_admin_set( hash: work_hash )
        work.update( admin_set: admin_set )
        work.save!
        work.reload
        log_provenance_ingest( curation_concern: work )
        return work
      end

      def build_works
        return unless works
        works.each do |work_hash|
          work = build_or_find_work( work_hash: work_hash, parent: nil )
          log_object work if work.present?
        end
      end

      def collections
        @collections ||= collections_from_hash( hash: @cfg_hash[:user] )
      end

      def collections_from_hash( hash: )
        [hash[:collections]]
      end

      def cfg_hash_value( base_key: :config, key:, default_value: )
        rv = default_value
        if @cfg_hash.key? base_key
          rv = @cfg_hash[base_key][key] if @cfg_hash[base_key].key? key
        end
        return rv
      end

      def default_admin_set
        @default_admin_set ||= AdminSet.find( AdminSet::DEFAULT_ID )
        # @default_admin_set ||= AdminSet.find_or_create_default_admin_set_id
      end

      def file_from_file_set( file_set: )
        file = nil
        files = file_set.files
        unless files.nil? || files.size.zero?
          file = files[0]
          files.each do |f|
            file = f unless f.original_name.empty?
          end
        end
        return file
      end

      def file_set_checksum( file_set: )
        file = file_from_file_set( file_set: file_set )
        return file.checksum if file.present?
        return nil
      end

      def find_collection_using_id( id: )
        return nil if id.blank?
        Collection.find id
      rescue ActiveFedora::ObjectNotFoundError
        return nil
      end

      def find_collection_using_prior_id( prior_id: )
        return nil if prior_id.blank?
        Collection.all.each do |curation_concern|
          prior_ids = Array( curation_concern.prior_identifier )
          prior_ids.each do |id|
            return curation_concern if id == prior_id
          end
        end
        return nil
      end

      def find_data_set_using_id( id: )
        return nil if id.blank?
        DataSet.find id
      rescue ActiveFedora::ObjectNotFoundError
        return nil
      end

      def find_data_set_using_prior_id( prior_id:, parent: )
        return nil if prior_id.blank?
        if parent.present?
          parent.member_objects.each do |obj|
            next unless obj.is_a? DataSet
            prior_ids = Array( obj.prior_identifier )
            prior_ids.each do |id|
              return obj if id == prior_id
            end
          end
        end
        DataSet.all.each do |curation_concern|
          prior_ids = Array( curation_concern.prior_identifier )
          prior_ids.each do |id|
            return curation_concern if id == prior_id
          end
        end
        return nil
      end

      def find_file_set_using_id( id: )
        return nil if id.blank?
        FileSet.find id
      rescue ActiveFedora::ObjectNotFoundError
        return nil
      end

      def find_file_set_using_prior_id( prior_id:, parent: )
        return nil if prior_id.blank?
        return if parent.blank?
        parent.file_sets.each do |fs|
          prior_ids = Array( fs.prior_identifier )
          prior_ids.each do |id|
            return fs if id == prior_id
          end
        end
        FileSet.all.each do |fs|
          if fs.parent.present?
            return fs if fs.parent.present? && fs.parent_id == parent.id
            next
          end
          prior_ids = Array( fs.prior_identifier )
          prior_ids.each do |id|
            return fs if id == prior_id
          end
        end
        return nil
      end

      def find_or_create_user
        user = User.find_by(user_key: user_key) || create_user(user_key)
        raise UserNotFoundError, "User not found: #{user_key}" if user.nil?
        return user
      end

      def find_work( work_hash: )
        work_id = work_hash[:id]
        id = Array(work_id)
        # owner = Array(work_hash[:owner])
        work = DataSet.find id[0]
        raise UserNotFoundError, "Work not found: #{work_id}" if work.nil?
        return work
      end

      def find_works_and_add_files
        return unless works
        works.each do |work_hash|
          work = find_work( work_hash: work_hash )
          add_file_sets_to_work( work_hash: work_hash, work: work )
          work.apply_depositor_metadata( user_key )
          work.owner = user_key
          work.visibility = visibility_from_hash( hash: work_hash )
          work.save!
          log_object work
        end
      end

      def ingest_id
        @ingest_id ||= @cfg_hash[:user][:ingester]
      end

      def ingester
        @cfg_hash[:user][:ingester]
      end

      # rubocop:disable Rails/Output
      def initialize_with_msg( args:,
                               path_to_yaml_file:,
                               cfg_hash:,
                               base_path:,
                               msg: "NEW CONTENT SERVICE AT YOUR ... SERVICE",
                               **config )

        DeepBlueDocs::Application.config.provenance_log_echo_to_rails_logger = false
        ProvenanceHelper.echo_to_rails_logger = false
        verbose_init = false
        @args = args # TODO: args.to_hash
        puts "args=#{args}" if verbose_init
        # puts "args=#{JSON.pretty_print args.as_json}" if verbose_init
        puts "ENV['TMPDIR']=#{ENV['TMPDIR']}" if verbose_init
        puts "ENV['_JAVA_OPTIONS']=#{ENV['_JAVA_OPTIONS']}" if verbose_init
        tmpdir = ENV['TMPDIR']
        tmpdir = File.absolute_path( './tmp/' ) if tmpdir.blank?
        ENV['_JAVA_OPTIONS'] = "-Djava.io.tmpdir=#{tmpdir}"
        puts "ENV['_JAVA_OPTIONS']=#{ENV['_JAVA_OPTIONS']}" if verbose_init
        puts `echo $_JAVA_OPTIONS`.to_s if verbose_init
        @path_to_yaml_file = path_to_yaml_file
        @config = {}
        @config.merge!( config ) if config.present?
        @cfg_hash = cfg_hash
        @base_path = base_path
        @ingest_id = File.basename path_to_yaml_file
        @ingest_timestamp = DateTime.now
        logger.info msg if msg.present?
      end
      # rubocop:enable Rails/Output

      def log_msg( msg )
        return if msg.blank?
        logger.info "#{timestamp_now} #{msg}"
      end

      def log_object( obj )
        id = if obj.respond_to?( :has_attribute? ) && obj.has_attribute?( :prior_identifier )
               "#{obj.id} prior id: #{Array( obj.prior_identifier )}"
             else
               obj.id.to_s
             end
        log_msg "#{mode}: #{obj.class.name} id: #{id} title: #{obj.title.first}"
      end

      def log_provenance_add_child( parent:, child: )
        return unless parent.respond_to? :provenance_ingest
        parent.provenance_child_add( current_user: user,
                                     child_id: child.id,
                                     ingest_id: ingest_id,
                                     ingester: ingester,
                                     ingest_timestamp: ingest_timestamp )
      end

      def log_provenance_ingest( curation_concern: )
        return unless curation_concern.respond_to? :provenance_ingest
        curation_concern.provenance_ingest( current_user: user,
                                            ingest_id: ingest_id,
                                            ingester: ingester,
                                            ingest_timestamp: ingest_timestamp )
      end

      def logger
        @logger ||= logger_initialize
      end

      def logger_initialize
        # TODO: add some flags to the input yml file for log level and Rails logging integration
        # rubocop:disable Style/Semicolon
        Deepblue::TaskLogger.new(STDOUT).tap { |logger| logger.level = logger_level; Rails.logger = logger }
        # rubocop:enable Style/Semicolon
      end

      def logger_level
        rv = cfg_hash_value( key: :logger_level, default_value: 'info' )
        return rv
      end

      def mode
        # @mode ||= @cfg_hash[:user][:mode]
        @mode ||= cfg_hash_value( base_key: :user, key: :mode, default_value: MODE_APPEND )
      end

      def new_collection( creator:,
                          curation_notes_admin:,
                          curation_notes_user:,
                          date_created:,
                          date_modified:,
                          date_uploaded:,
                          description:,
                          id:,
                          keyword:,
                          language:,
                          prior_identifier:,
                          referenced_by:,
                          resource_type:,
                          subject_discipline:,
                          title: )

        if id.present?
          Collection.new( creator: creator,
                          curation_notes_admin: curation_notes_admin,
                          curation_notes_user: curation_notes_user,
                          date_created: date_created,
                          date_modified: date_modified,
                          date_uploaded: date_uploaded,
                          description: description,
                          id: id,
                          keyword: keyword,
                          language: language,
                          prior_identifier: prior_identifier,
                          referenced_by: referenced_by,
                          resource_type: resource_type,
                          subject_discipline: subject_discipline,
                          title: title )
        else
          Collection.new( creator: creator,
                          curation_notes_admin: curation_notes_admin,
                          curation_notes_user: curation_notes_user,
                          date_created: date_created,
                          date_modified: date_modified,
                          date_uploaded: date_uploaded,
                          description: description,
                          keyword: keyword,
                          language: language,
                          prior_identifier: prior_identifier,
                          referenced_by: referenced_by,
                          resource_type: resource_type,
                          subject_discipline: subject_discipline,
                          title: title )
        end
      end

      def new_data_set( authoremail:,
                        contributor:,
                        creator:,
                        curation_notes_admin:,
                        curation_notes_user:,
                        date_coverage:,
                        date_created:,
                        date_modified:,
                        date_uploaded:,
                        description:,
                        fundedby:,
                        fundedby_other:,
                        grantnumber:,
                        id:,
                        keyword:,
                        language:,
                        methodology:,
                        prior_identifier:,
                        referenced_by:,
                        resource_type:,
                        rights_license:,
                        rights_license_other:,
                        subject_discipline:,
                        title: )
        if id.present?
          DataSet.new( authoremail: authoremail,
                       contributor: contributor,
                       creator: creator,
                       curation_notes_admin: curation_notes_admin,
                       curation_notes_user: curation_notes_user,
                       date_coverage: date_coverage,
                       date_created: date_created,
                       date_modified: date_modified,
                       date_uploaded: date_uploaded,
                       description: description,
                       fundedby: fundedby,
                       fundedby_other: fundedby_other,
                       grantnumber: grantnumber,
                       id: id,
                       keyword: keyword,
                       language: language,
                       methodology: methodology,
                       prior_identifier: prior_identifier,
                       referenced_by: referenced_by,
                       resource_type: resource_type,
                       rights_license: rights_license,
                       rights_license_other: rights_license_other,
                       subject_discipline: subject_discipline,
                       title: title )
        else
          DataSet.new( authoremail: authoremail,
                       contributor: contributor,
                       creator: creator,
                       curation_notes_admin: curation_notes_admin,
                       curation_notes_user: curation_notes_user,
                       date_coverage: date_coverage,
                       date_created: date_created,
                       date_modified: date_modified,
                       date_uploaded: date_uploaded,
                       description: description,
                       fundedby: fundedby,
                       fundedby_other: fundedby_other,
                       grantnumber: grantnumber,
                       keyword: keyword,
                       language: language,
                       methodology: methodology,
                       prior_identifier: prior_identifier,
                       referenced_by: referenced_by,
                       resource_type: resource_type,
                       rights_license: rights_license,
                       rights_license_other: rights_license_other,
                       subject_discipline: subject_discipline,
                       title: title )
        end
      end

      def new_file_set( id: )
        if id.present?
          FileSet.new( id: id )
        else
          FileSet.new
        end
      end

      def source
        @source ||= valid_restricted_vocab( @cfg_hash[:user][:source], var: :source, vocab: %w[DBDv1 DBDv2] )
      end

      def timestamp_now
        Time.now.to_formatted_s(:db )
      end

      def update_cc_attribute(curation_concern:, attribute:, value: )
        curation_concern[attribute] = value
      end

      def update_collection( collection:,
                             creator:,
                             curation_notes_admin:,
                             curation_notes_user:,
                             date_created:,
                             date_modified:,
                             date_uploaded:,
                             description:,
                             keyword:,
                             language:,
                             methodology:,
                             prior_identifier:,
                             referenced_by:,
                             resource_type:,
                             subject_discipline:,
                             title: )

        # TODO: provenance
        update_cc_attribute(curation_concern: collection, attribute: :creator, value: creator )
        update_cc_attribute(curation_concern: collection, attribute: :curation_notes_admin, value: curation_notes_admin )
        update_cc_attribute(curation_concern: collection, attribute: :curation_notes_user, value: curation_notes_user )
        update_cc_attribute(curation_concern: collection, attribute: :date_created, value: date_created )
        update_cc_attribute(curation_concern: collection, attribute: :date_modified, value: date_modified )
        update_cc_attribute(curation_concern: collection, attribute: :date_uploaded, value: date_uploaded )
        update_cc_attribute(curation_concern: collection, attribute: :description, value: description )
        update_cc_attribute(curation_concern: collection, attribute: :keyword, value: keyword )
        update_cc_attribute(curation_concern: collection, attribute: :language, value: language )
        update_cc_attribute(curation_concern: collection, attribute: :methodology, value: methodology )
        update_cc_attribute(curation_concern: collection, attribute: :prior_identifier, value: prior_identifier )
        update_cc_attribute(curation_concern: collection, attribute: :referenced_by, value: referenced_by )
        update_cc_attribute(curation_concern: collection, attribute: :resource_type, value: resource_type )
        update_cc_attribute(curation_concern: collection, attribute: :subject_discipline, value: subject_discipline )
        update_cc_attribute(curation_concern: collection, attribute: :title, value: title )
        collection.save!
        collection.reload
        return collection
      end

      def update_work( work:,
                       authoremail:,
                       contributor:,
                       creator:,
                       curation_notes_admin:,
                       curation_notes_user:,
                       date_coverage:,
                       date_created:,
                       date_modified:,
                       date_uploaded:,
                       description:,
                       fundedby:,
                       fundedby_other:,
                       grantnumber:,
                       keyword:,
                       language:,
                       methodology:,
                       prior_identifier:,
                       referenced_by:,
                       resource_type:,
                       rights_license:,
                       rights_license_other:,
                       subject_discipline:,
                       title: )

        # TODO: provenance
        update_cc_attribute(curation_concern: work, attribute: :authoremail, value: authoremail )
        update_cc_attribute(curation_concern: work, attribute: :contributor, value: contributor )
        update_cc_attribute(curation_concern: work, attribute: :creator, value: creator )
        update_cc_attribute(curation_concern: work, attribute: :curation_notes_admin, value: curation_notes_admin )
        update_cc_attribute(curation_concern: work, attribute: :curation_notes_user, value: curation_notes_user )
        update_cc_attribute(curation_concern: work, attribute: :date_coverage, value: date_coverage )
        update_cc_attribute(curation_concern: work, attribute: :date_created, value: date_created )
        update_cc_attribute(curation_concern: work, attribute: :date_modified, value: date_modified )
        update_cc_attribute(curation_concern: work, attribute: :date_uploaded, value: date_uploaded )
        update_cc_attribute(curation_concern: work, attribute: :description, value: description )
        update_cc_attribute(curation_concern: work, attribute: :fundedby, value: fundedby )
        update_cc_attribute(curation_concern: work, attribute: :fundedby_other, value: fundedby_other )
        update_cc_attribute(curation_concern: work, attribute: :grantnumber, value: grantnumber )
        update_cc_attribute(curation_concern: work, attribute: :keyword, value: keyword )
        update_cc_attribute(curation_concern: work, attribute: :language, value: language )
        update_cc_attribute(curation_concern: work, attribute: :methodology, value: methodology )
        update_cc_attribute(curation_concern: work, attribute: :prior_identifier, value: prior_identifier )
        update_cc_attribute(curation_concern: work, attribute: :referenced_by, value: referenced_by )
        update_cc_attribute(curation_concern: work, attribute: :resource_type, value: resource_type )
        update_cc_attribute(curation_concern: work, attribute: :rights_license, value: rights_license )
        update_cc_attribute(curation_concern: work, attribute: :rights_license_other, value: rights_license_other )
        update_cc_attribute(curation_concern: work, attribute: :subject_discipline, value: subject_discipline )
        update_cc_attribute(curation_concern: work, attribute: :title, value: title )
        work.save!
        work.reload
        return work
      end

      def update_file_set( file_set:,
                           curation_notes_admin:,
                           curation_notes_user:,
                           date_created:,
                           date_modified:,
                           date_uploaded:,
                           prior_identifier:,
                           title: )

        # TODO: provenance
        update_cc_attribute(curation_concern: file_set, attribute: :curation_notes_admin, value: curation_notes_admin )
        update_cc_attribute(curation_concern: file_set, attribute: :curation_notes_user, value: curation_notes_user )
        update_cc_attribute(curation_concern: file_set, attribute: :date_created, value: date_created )
        update_cc_attribute(curation_concern: file_set, attribute: :date_modified, value: date_modified )
        update_cc_attribute(curation_concern: file_set, attribute: :date_uploaded, value: date_uploaded )
        update_cc_attribute(curation_concern: file_set, attribute: :prior_identifier, value: prior_identifier )
        update_cc_attribute(curation_concern: file_set, attribute: :title, value: title )
        collection.save!
        collection.reload
        return collection
      end

      def update_visibility( curation_concern:, visibility: )
        return unless visibility_curation_concern visibility
        curation_concern.visibility = visibility
      end

      def user_key
        # TODO: validate the email
        @cfg_hash[:user][:email]
      end

      # config needs default user to attribute collections/works/filesets to
      # User needs to have only works or collections
      def validate_config
        # if @cfg_hash.keys != [:user]
        unless @cfg_hash.key?( :user )
          raise TaskConfigError, "Top level keys needs to contain 'user'"
        end
        # rubocop:disable Style/GuardClause
        if (@cfg_hash[:user].keys <=> %i[collections works]) < 1
          raise TaskConfigError, "user can only contain collections and works"
        end
        # rubocop:enable Style/GuardClause
      end

      def valid_restricted_vocab( value, var:, vocab:, error_class: RestrictedVocabularyError )
        unless vocab.include? value
          raise error_class, "Illegal value '#{value}' #{var}, must be one of #{vocab}"
        end
        return value
      end

      def visibility
        @visibility ||= visibility_curation_concern( @cfg_hash[:user][:visibility] )
      end

      def visibility_curation_concern( vis )
        return valid_restricted_vocab( vis,
                                       var: :visibility,
                                       vocab: %w[open restricted],
                                       error_class: VisibilityError )
      end

      def visibility_from_hash( hash: )
        vis = hash[:visibility]
        return visibility_curation_concern( vis ) if vis.present?
        visibility
      end

      def works
        @works ||= works_from_hash( hash: @cfg_hash[:user] )
      end

      def works_from_hash( hash: )
        [hash[:works]]
      end

      def works_from_id( hash:, work_id: )
        id_key = "works_#{work_id}".to_sym
        # puts "id_key=#{id_key}"
        hash[id_key]
      end

  end

end
