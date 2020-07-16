git_plugin = self

namespace :sidekiq do
  desc 'Quiet sidekiq (stop fetching new tasks from Redis)'
  task :quiet do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        git_plugin.each_process_with_index do |process_name, options, index|
          if fetch(:sidekiq_service_unit_user) == :system
            execute :sudo, :systemctl, "reload", process_name, raise_on_non_zero_exit: false
          else
            execute :systemctl, "--user", "reload", process_name, raise_on_non_zero_exit: false
          end
        end
      end
    end
  end

  desc 'Stop sidekiq (graceful shutdown within timeout, put unfinished tasks back to Redis)'
  task :stop do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        git_plugin.each_process_with_index do |process_name, options, index|
          if fetch(:sidekiq_service_unit_user) == :system
            execute :sudo, :systemctl, "stop", process_name
          else
            execute :systemctl, "--user", "stop", process_name
          end
        end
      end
    end
  end

  desc 'Start sidekiq'
  task :start do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        git_plugin.each_process_with_index do |process_name, options, index|
          if fetch(:sidekiq_service_unit_user) == :system
            execute :sudo, :systemctl, 'start', process_name
          else
            execute :systemctl, '--user', 'start', process_name
          end
        end
      end
    end
  end

  desc 'Install systemd sidekiq service'
  task :install do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        git_plugin.each_process_with_index do |process_name, options, index|
          git_plugin.create_systemd_template(index)

          if fetch(:sidekiq_service_unit_user) == :system
            execute :sudo, :systemctl, "enable", process_name
          else
            execute :systemctl, "--user", "enable", process_name
            execute :loginctl, "enable-linger", fetch(:sidekiq_lingering_user) if fetch(:sidekiq_enable_lingering)
          end
        end
      end
    end
  end

  desc 'UnInstall systemd sidekiq service'
  task :uninstall do
    on roles fetch(:sidekiq_roles) do |role|
      git_plugin.switch_user(role) do
        git_plugin.each_process_with_index do |process_name, options, index|
          if fetch(:sidekiq_service_unit_user) == :system
            execute :sudo, :systemctl, "disable", process_name
          else
            execute :systemctl, "--user", "disable", process_name
          end

          execute :rm, '-f', File.join(fetch(:service_unit_path, fetch_systemd_unit_path), process_name)
        end
      end
    end
  end

  desc 'Generate service_locally'
  task :generate_service_locally do
    run_locally do
      File.write('sidekiq', git_plugin.compiled_template)
    end
  end

  def each_process_with_index
    if fetch(:sidekiq_options_per_process) != nil
      fetch(:sidekiq_options_per_process).each_with_index do |options, index|
        process_name = "#{fetch(:sidekiq_service_unit_name)}-#{index}"

        yield process_name, options, index
      end
    else
      process_name = fetch(:sidekiq_service_unit_name)
      options = nil
      index = nil

      yield process_name, options, index
    end
  end

  def fetch_systemd_unit_path
    if fetch(:sidekiq_service_unit_user) == :system
      # if the path is not standard `set :service_unit_path`
      "/etc/systemd/system/"
    else
      home_dir = backend.capture :pwd
      File.join(home_dir, ".config", "systemd", "user")
    end
  end

  def create_systemd_template(index)
    ctemplate = compiled_template(index)
    systemd_path = fetch(:service_unit_path, fetch_systemd_unit_path)
    process_name = "#{fetch(:sidekiq_service_unit_name)}-#{index}"

    if fetch(:sidekiq_service_unit_user) == :user
      backend.execute :mkdir, "-p", systemd_path
    end

    backend.upload!(StringIO.new(ctemplate), "/tmp/#{process_name}.service")

    if fetch(:sidekiq_service_unit_user) == :system
      backend.execute :sudo, :mv, "/tmp/#{process_name}.service", "#{systemd_path}/#{process_name}.service"
      backend.execute :sudo, :systemctl, "daemon-reload"
    else
      backend.execute :mv, "/tmp/#{process_name}.service", "#{systemd_path}/#{process_name}.service"
      backend.execute :systemctl, "--user", "daemon-reload"
    end
  end

  def compiled_template(index = nil)
    search_paths = [
      File.expand_path(
          File.join(*%w[.. .. .. generators capistrano sidekiq systemd templates sidekiq.service.capistrano.erb]),
          __FILE__
      ),
    ]
    template_path = search_paths.detect { |path| File.file?(path) }
    template = File.read(template_path)
    ERB.new(template).result(binding)
  end

  def switch_user(role)
    su_user = sidekiq_user
    if su_user != role.user
      yield
    else
      backend.as su_user do
        yield
      end
    end
  end

  def sidekiq_user
    fetch(:sidekiq_user, fetch(:run_as))
  end
end
