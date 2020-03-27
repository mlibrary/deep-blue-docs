# frozen_string_literal: true

class SchedulerStartJob < ::Hyrax::ApplicationJob
  include JobHelper
  queue_as :default

  # job_delay in seconds
  def perform( job_delay: ::Deepblue::SchedulerIntegrationService.scheduler_start_job_default_delay, restart: true, **options )
    ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                           Deepblue::LoggingHelper.called_from,
                                           Deepblue::LoggingHelper.obj_class( 'class', self ),
                                           "options=#{options}",
                                           "" ]

    sleep job_delay if job_delay > 0
    restarted = false
    pid = `pgrep -fu #{Process.uid} resque-scheduler`
    if restart
      `kill -9 #{pid}` if pid.present?
      sleep 1.second
      pid = `pgrep -fu #{Process.uid} resque-scheduler`
      if pid.present?
        scheduler_emails( subject: "DBD scheduler failed to kill resque-scheduler on #{hostname}" )
        return
      end
      restarted = pid.blank?
    elsif pid.present?
      scheduler_emails( subject: "DBD scheduler already running on #{hostname}" )
      return
    end
    rails_bin_scheduler = Rails.application.root.join( 'bin' ).join( 'scheduler.sh' )
    rails_log_scheduler = Rails.application.root.join( 'log' ).join( 'scheduler.sh.out' )
    cmd = "nohup #{rails_bin_scheduler} 2>&1 >> #{rails_log_scheduler} &"
    ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                           Deepblue::LoggingHelper.called_from,
                                           Deepblue::LoggingHelper.obj_class( 'class', self ),
                                           "rails_bin_scheduler=#{rails_bin_scheduler}",
                                           "rails_log_scheduler=#{rails_log_scheduler}",
                                           "cmd=#{cmd}",
                                           "" ]
    rv = `#{cmd}`
    ::Deepblue::LoggingHelper.bold_debug [ Deepblue::LoggingHelper.here,
                                           Deepblue::LoggingHelper.called_from,
                                           Deepblue::LoggingHelper.obj_class( 'class', self ),
                                           "cmd=#{cmd}",
                                           "cmd rv=#{rv}",
                                           "" ]
    retry_count = 0
    while retry_count < 5 # TODO configure retry count
      retry_count += 1
      sleep 5.seconds # TODO configure sleep time
      pid = `pgrep -fu #{Process.uid} resque-scheduler`
      break if pid.present?
    end
    msg_lines = []
    msg_lines << "rails_bin_scheduler = #{rails_bin_scheduler}"
    msg_lines << "rails_log_scheduler = #{rails_log_scheduler}"
    msg_lines << ''
    msg_lines << "cmd rv = #{rv}"
    msg_lines << ''
    msg_lines << "retry_count = #{retry_count}"
    subject = if pid.present?
                if restarted
                  "DBD scheduler restarted on #{hostname}"
                else
                  "DBD scheduler started on #{hostname}"
                end
              else
                "DBD scheduler failed to start on #{hostname}"
              end
    body = "#{subject}\n\n#{msg_lines.join("\n")}"
    scheduler_emails( subject: subject, body: body )
  rescue Exception => e # rubocop:disable Lint/RescueException
    Rails.logger.error "#{e.class} #{e.message} at #{e.backtrace[0]}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  def hostname
    DeepBlueDocs::Application.config.hostname
  end

  def scheduler_email( email_target:, subject:, body: nil )
    subject = subject
    body = body
    body = subject if body.empty?
    email = email_target
    email_sent = ::Deepblue::EmailHelper.send_email( to: email, from: email, subject: subject, body: body )
    ::Deepblue::EmailHelper.log( class_name: self.class.name,
                                 current_user: nil,
                                 event: "SchedulerStartJobEmail",
                                 event_note: '',
                                 id: 'NA',
                                 to: email,
                                 from: email,
                                 subject: subject,
                                 body: body,
                                 email_sent: email_sent )
  end

  def scheduler_emails( subject:, body: nil )
    ::Deepblue::SchedulerIntegrationService.scheduler_started_email.each do |email_target|
      scheduler_email( email_target: email_target, subject: subject, body: body )
    end
  end

end