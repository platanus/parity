require "etc"
require "erb"

module Parity
  class Backup
    BLANK_ARGUMENTS = "".freeze
    DATABASE_YML_RELATIVE_PATH = "config/database.yml".freeze
    DEVELOPMENT_ENVIRONMENT_KEY_NAME = "development".freeze
    DATABASE_KEY_NAME = "database".freeze
    DATABASE_USERNAME_KEY_NAME = "username".freeze
    DATABASE_PASSWORD_KEY_NAME = "password".freeze
    DATABASE_HOST_KEY_NAME = "host".freeze
    DATABASE_PORT_KEY_NAME = "port".freeze

    def initialize(args)
      @from, @to = args.values_at(:from, :to)
      @additional_args = args[:additional_args] || BLANK_ARGUMENTS
      @connection_flags = connection_flags
    end

    def restore
      if to == DEVELOPMENT_ENVIRONMENT_KEY_NAME
        restore_to_development
      elsif from == DEVELOPMENT_ENVIRONMENT_KEY_NAME
        restore_from_development
      else
        restore_to_remote_environment
      end
    end

    private

    attr_reader :additional_args, :connection_flags, :database_config, :from, :to

    def restore_from_development
      reset_remote_database
      Kernel.system(
        "heroku pg:push #{development_db} DATABASE_URL --remote #{to} "\
          "#{additional_args}",
      )
    end

    def restore_to_development
      ensure_temp_directory_exists
      download_remote_backup
      wipe_development_database
      restore_from_local_temp_backup
      delete_local_temp_backup
      delete_rails_production_environment_settings
    end

    def wipe_development_database
      Kernel.system(
        "dropdb #{connection_flags} --if-exists #{development_db} && createdb #{connection_flags} #{development_db}",
      )
    end

    def reset_remote_database
      Kernel.system(
        "heroku pg:reset --remote #{to} #{additional_args} "\
          "--confirm #{heroku_app_name}",
      )
    end

    def heroku_app_name
      HerokuAppName.new(to).to_s
    end

    def ensure_temp_directory_exists
      Kernel.system("mkdir -p tmp")
    end

    def download_remote_backup
      Kernel.system(
        "curl -o tmp/latest.backup \"$(heroku pg:backups:url --remote #{from})\"",
      )
    end

    def restore_from_local_temp_backup
      Kernel.system(
        "pg_restore tmp/latest.backup --verbose --clean --no-acl --no-owner "\
          "--dbname #{development_db} --jobs=#{processor_cores} "\
          "#{connection_flags} #{additional_args}",
      )
    end

    def delete_local_temp_backup
      Kernel.system("rm tmp/latest.backup")
    end

    def delete_rails_production_environment_settings
      Kernel.system(<<-SHELL)
        psql #{development_db} #{connection_flags} -c "CREATE TABLE IF NOT EXISTS public.ar_internal_metadata (key character varying NOT NULL, value character varying, created_at timestamp without time zone NOT NULL, updated_at timestamp without time zone NOT NULL, CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key)); UPDATE ar_internal_metadata SET value = 'development' WHERE key = 'environment'"
      SHELL
    end

    def restore_to_remote_environment
      reset_remote_database
      Kernel.system(
        "heroku pg:backups:restore #{backup_from} --remote #{to} "\
          "#{additional_args}",
      )
    end

    def backup_from
      "`#{remote_db_backup_url}` DATABASE"
    end

    def remote_db_backup_url
      "heroku pg:backups:url --remote #{from}"
    end

    def connection_flags
      flags = []
      flags << "--username #{development_user}" unless development_user.nil?
      flags << "--password #{development_password}" unless development_password.nil?
      flags << "--host #{development_host}" unless development_host.nil?
      flags << "--port #{development_port}" unless development_port.nil?
      flags.join(' ')
    end

    def development_db
      database_config.
        fetch(DEVELOPMENT_ENVIRONMENT_KEY_NAME).
        fetch(DATABASE_KEY_NAME)
    end

    def development_user
      database_config.
        fetch(DEVELOPMENT_ENVIRONMENT_KEY_NAME).
        fetch(DATABASE_USERNAME_KEY_NAME, nil)
    end

    def development_password
      database_config.
        fetch(DEVELOPMENT_ENVIRONMENT_KEY_NAME).
        fetch(DATABASE_PASSWORD_KEY_NAME, nil)
    end

    def development_host
      database_config.
        fetch(DEVELOPMENT_ENVIRONMENT_KEY_NAME).
        fetch(DATABASE_HOST_KEY_NAME, nil)
    end

    def development_port
      database_config.
        fetch(DEVELOPMENT_ENVIRONMENT_KEY_NAME).
        fetch(DATABASE_PORT_KEY_NAME, nil)
    end

    def database_config
      @database_config ||= YAML.load(database_yaml_file)
    end

    def database_yaml_file
      ERB.new(IO.read(DATABASE_YML_RELATIVE_PATH)).result(binding)
    end

    def processor_cores
      if ruby_version_over_2_2?
        Etc.nprocessors
      else
        2
      end
    end

    def ruby_version_over_2_2?
      Etc.respond_to?(:nprocessors)
    end
  end
end
