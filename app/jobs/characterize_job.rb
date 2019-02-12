# frozen_string_literal: true

class CharacterizeJob < ::Hyrax::ApplicationJob
  queue_as Hyrax.config.ingest_queue_name

  # @param [FileSet] file_set
  # @param [String] repository_file_id identifier for a Hydra::PCDM::File
  # @param [String, NilClass] filepath the cached file within the Hyrax.config.working_path
  def perform( file_set,
               repository_file_id,
               filepath = nil,
               continue_job_chain: true,
               continue_job_chain_later: true,
               delete_input_file: true )

    Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                         Deepblue::LoggingHelper.called_from,
                                         "file_set=#{file_set})",
                                         "repository_file_id=#{repository_file_id}",
                                         "filepath=#{filepath}",
                                         "continue_job_chain=#{continue_job_chain}",
                                         "continue_job_chain_later=#{continue_job_chain_later}",
                                         "delete_input_file=#{delete_input_file}",
                                         "" ]
    Deepblue::IngestHelper.characterize( file_set,
                                         repository_file_id,
                                         filepath,
                                         continue_job_chain: continue_job_chain,
                                         continue_job_chain_later: continue_job_chain_later,
                                         delete_input_file: delete_input_file )
  rescue Exception => e # rubocop:disable Lint/RescueException
    Rails.logger.error "CharacterizeJob.perform(#{file_set},#{repository_file_id},#{filepath}) #{e.class}: #{e.message}"
  end

end
