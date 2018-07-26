require 'spec_helper'

RSpec.describe 'clear process.command for buildpack-created apps', isolation: :truncation do
  def run_migration
    Sequel::Migrator.run(VCAP::CloudController::AppModel.db, tmp_migrations_dir, table: :my_fake_table)
  end

  let(:tmp_migrations_dir) {Dir.mktmpdir}

  before do
    FileUtils.cp(
      File.join(DBMigrator::SEQUEL_MIGRATIONS, '20180726120275_clear_process_command_for_buildpacks.rb'),
      tmp_migrations_dir,
    )
  end

  let(:app) { VCAP::CloudController::AppModel.make(droplet: droplet) }
  let!(:process) { VCAP::CloudController::ProcessModelFactory.make(app: app, command: 'the-command') }
  let(:droplet) { VCAP::CloudController::DropletModel.make(process_types: { web: 'detected-command-web'}) }

  it 'nils out a Process.command if its Droplet has a matching detected command' do

    expect(droplet.reload.process_types).to eq(false)

    HEY NERDS
    START HERE TOMORROW
    YOUR EXPECTATIONS DON'T MATCH YOUR IT STATEMENT.
THIS DOC WAS REALLY GOOD: https://docs.google.com/document/d/1T2hf8IoLI5fcXOQiW7HyJ1gIpDX4X7TvSEGUbrYpRa8/edit

    run_migration

    expect(process.reload.command).to be_nil
  end

end
