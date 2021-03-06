require 'rugged'

describe ManageIQ::Providers::EmbeddedAnsible::AutomationManager::ConfigurationScriptSource do
  context "with a local repo" do
    let(:manager) do
      FactoryBot.create(:provider_embedded_ansible, :default_organization => 1).managers.first
    end

    let(:params) do
      {
        :name    => "hello_world",
        :scm_url => "file://#{local_repo}"
      }
    end

    let(:clone_dir)  { Dir.mktmpdir }
    let(:local_repo) { File.join(clone_dir, "hello_world_local") }
    let(:repo_dir)   { Pathname.new(Dir.mktmpdir) }
    let(:repos)      { Dir.glob(File.join(repo_dir, "*")) }

    before do
      # START: Setup local repo used for this spec
      FileUtils.mkdir_p(local_repo)
      File.write(File.join(local_repo, "hello_world.yaml"), <<~PLAYBOOK)
        - name: Hello World Sample
          hosts: all
          tasks:
            - name: Hello Message
              debug:
                msg: "Hello World!"

      PLAYBOOK

      # Init new repo at local_repo
      #
      #   $ cd /tmp/clone_dir/hello_world_local && git init .
      repo  = Rugged::Repository.init_at(local_repo)
      index = repo.index

      # Add new files to index
      #
      #   $ git add .
      index.add_all
      index.write

      # Create initial commit
      #
      #   $ git commit -m "Initial Commit"
      Rugged::Commit.create(
        repo,
        :message    => "Initial Commit",
        :parents    => [],
        :tree       => index.write_tree(repo),
        :update_ref => "HEAD"
      )

      # Create a new branch (don't checkout)
      #
      #   $ git branch other_branch
      repo.create_branch("other_branch")
      # END: Setup local repo used for this spec

      GitRepository
      stub_const("GitRepository::GIT_REPO_DIRECTORY", repo_dir)

      EvmSpecHelper.assign_embedded_ansible_role
    end

    # Clean up repo dir after each spec
    after do
      FileUtils.rm_rf(repo_dir)
      FileUtils.rm_rf(clone_dir)
    end

    def files_in_repository(git_repo_dir)
      repo = Rugged::Repository.new(git_repo_dir.to_s)
      repo.ref("HEAD").target.target.tree.find_all.map { |f| f[:name] }
    end

    describe ".create_in_provider" do
      let(:notify_creation_args) { notification_args('creation') }

      context "with valid params" do
        it "creates a record and initializes a git repo" do
          expect(Notification).to receive(:create!).with(notify_creation_args)
          expect(Notification).to receive(:create!).with(notification_args("syncing", {}))

          result = described_class.create_in_provider(manager.id, params)

          expect(result).to be_an(described_class)
          expect(result.scm_type).to eq("git")
          expect(result.scm_branch).to eq("master")
          expect(result.status).to eq("successful")
          expect(result.last_updated_on).to be_an(Time)
          expect(result.last_update_error).to be_nil

          git_repo_dir = repo_dir.join(result.git_repository.id.to_s)
          expect(files_in_repository(git_repo_dir)).to eq ["hello_world.yaml"]
        end

        # NOTE:  Second `.notify` stub below prevents `.sync` from getting fired
        it "sets the status to 'new' on create" do
          expect(Notification).to receive(:create!).with(notify_creation_args)
          expect(described_class).to receive(:notify).with(any_args).and_call_original
          expect(described_class).to receive(:notify).with("syncing", any_args).and_return(true)

          result = described_class.create_in_provider(manager.id, params)

          expect(result).to be_an(described_class)
          expect(result.scm_type).to eq("git")
          expect(result.scm_branch).to eq("master")
          expect(result.status).to eq("new")
          expect(result.last_updated_on).to be_nil
          expect(result.last_update_error).to be_nil

          expect(repos).to be_empty
        end
      end

      context "with invalid params" do
        it "does not create a record and does not call git" do
          params[:name]               = nil
          notify_creation_args[:type] = :tower_op_failure

          expect(AwesomeSpawn).to receive(:run!).never
          expect(Notification).to receive(:create!).with(notify_creation_args)

          expect do
            described_class.create_in_provider manager.id, params
          end.to raise_error(ActiveRecord::RecordInvalid)

          expect(repos).to be_empty
        end
      end

      context "when there is a network error fetching the repo" do
        before do
          sync_notification_args        = notification_args("syncing", {})
          sync_notification_args[:type] = :tower_op_failure

          expect(Notification).to receive(:create!).with(notify_creation_args)
          expect(Notification).to receive(:create!).with(sync_notification_args)
          allow_any_instance_of(GitRepository).to receive(:with_worktree).and_raise(::Rugged::NetworkError)

          expect do
            described_class.create_in_provider(manager.id, params)
          end.to raise_error(::Rugged::NetworkError)
        end

        it "sets the status to 'error' if syncing has a network error" do
          result = described_class.last

          expect(result).to be_an(described_class)
          expect(result.scm_type).to eq("git")
          expect(result.scm_branch).to eq("master")
          expect(result.status).to eq("error")
          expect(result.last_updated_on).to be_an(Time)
          expect(result.last_update_error).to start_with("Rugged::NetworkError")

          expect(repos).to be_empty
        end

        it "clears last_update_error on re-sync" do
          result = described_class.last

          expect(result.status).to eq("error")
          expect(result.last_updated_on).to be_an(Time)
          expect(result.last_update_error).to start_with("Rugged::NetworkError")

          allow_any_instance_of(GitRepository).to receive(:with_worktree).and_call_original

          result.sync

          expect(result.status).to eq("successful")
          expect(result.last_update_error).to be_nil
        end
      end
    end

    describe ".create_in_provider_queue" do
      it "creates a task and queue item" do
        EvmSpecHelper.local_miq_server
        task_id = described_class.create_in_provider_queue(manager.id, params)
        expect(MiqTask.find(task_id)).to have_attributes(:name => "Creating #{described_class::FRIENDLY_NAME} (name=#{params[:name]})")
        expect(MiqQueue.first).to have_attributes(
          :args        => [manager.id, params],
          :class_name  => described_class.name,
          :method_name => "create_in_provider",
          :priority    => MiqQueue::HIGH_PRIORITY,
          :role        => "embedded_ansible",
          :zone        => nil
        )
      end
    end

    describe "#update_in_provider" do
      let(:update_params)      { { :scm_branch => "other_branch" } }
      let(:notify_update_args) { notification_args('update', update_params) }

      context "with valid params" do
        it "updates the record and initializes a git repo" do
          record = build_record

          expect(Notification).to receive(:create!).with(notify_update_args)
          expect(Notification).to receive(:create!).with(notification_args("syncing", {}))

          result = record.update_in_provider update_params

          expect(result).to be_an(described_class)
          expect(result.scm_branch).to eq("other_branch")

          git_repo_dir = repo_dir.join(result.git_repository.id.to_s)
          expect(files_in_repository(git_repo_dir)).to eq ["hello_world.yaml"]
        end
      end

      context "with invalid params" do
        it "does not create a record and does not call git" do
          record                    = build_record
          update_params[:scm_type]  = 'svn' # oh dear god...
          notify_update_args[:type] = :tower_op_failure

          expect(AwesomeSpawn).to receive(:run!).never
          expect(Notification).to receive(:create!).with(notify_update_args)

          expect do
            record.update_in_provider update_params
          end.to raise_error(ActiveRecord::RecordInvalid)
        end
      end

      context "when there is a network error fetching the repo" do
        before do
          record = build_record

          sync_notification_args        = notification_args("syncing", {})
          sync_notification_args[:type] = :tower_op_failure

          expect(Notification).to receive(:create!).with(notify_update_args)
          expect(Notification).to receive(:create!).with(sync_notification_args)
          expect(record.git_repository).to receive(:update_repo).and_raise(::Rugged::NetworkError)

          expect do
            # described_class.last.update_in_provider update_params
            record.update_in_provider update_params
          end.to raise_error(::Rugged::NetworkError)
        end

        it "sets the status to 'error' if syncing has a network error" do
          result = described_class.last

          expect(result).to be_an(described_class)
          expect(result.scm_type).to eq("git")
          expect(result.scm_branch).to eq("other_branch")
          expect(result.status).to eq("error")
          expect(result.last_updated_on).to be_an(Time)
          expect(result.last_update_error).to start_with("Rugged::NetworkError")
        end

        it "clears last_update_error on re-sync" do
          result = described_class.last

          expect(result.status).to eq("error")
          expect(result.last_updated_on).to be_an(Time)
          expect(result.last_update_error).to start_with("Rugged::NetworkError")

          expect(result.git_repository).to receive(:update_repo).and_call_original

          result.sync

          expect(result.status).to eq("successful")
          expect(result.last_update_error).to be_nil
        end
      end
    end

    describe "#update_in_provider_queue" do
      it "creates a task and queue item" do
        record    = build_record
        task_id   = record.update_in_provider_queue({})
        task_name = "Updating #{described_class::FRIENDLY_NAME} (name=#{record.name})"

        expect(MiqTask.find(task_id)).to have_attributes(:name => task_name)
        expect(MiqQueue.first).to have_attributes(
          :instance_id => record.id,
          :args        => [{:task_id => task_id}],
          :class_name  => described_class.name,
          :method_name => "update_in_provider",
          :priority    => MiqQueue::HIGH_PRIORITY,
          :role        => "embedded_ansible",
          :zone        => nil
        )
      end
    end

    describe "#delete_in_provider" do
      it "deletes the record and removes the git dir" do
        record = build_record
        git_repo_dir = repo_dir.join(record.git_repository.id.to_s)

        expect(Notification).to receive(:create!).with(notification_args('deletion', {}))
        record.delete_in_provider

        expect { record.reload }.to raise_error ActiveRecord::RecordNotFound

        expect(git_repo_dir).to_not exist
      end
    end

    describe "#delete_in_provider_queue" do
      it "creates a task and queue item" do
        record    = build_record
        task_id   = record.delete_in_provider_queue
        task_name = "Deleting #{described_class::FRIENDLY_NAME} (name=#{record.name})"

        expect(MiqTask.find(task_id)).to have_attributes(:name => task_name)
        expect(MiqQueue.first).to have_attributes(
          :instance_id => record.id,
          :args        => [],
          :class_name  => described_class.name,
          :method_name => "delete_in_provider",
          :priority    => MiqQueue::HIGH_PRIORITY,
          :role        => "embedded_ansible",
          :zone        => nil
        )
      end
    end

    def build_record
      expect(Notification).to receive(:create!).with(any_args).twice
      described_class.create_in_provider manager.id, params
    end

    def notification_args(action, op_arg = params)
      {
        :type    => :tower_op_success,
        :options => {
          :op_name => "#{described_class::FRIENDLY_NAME} #{action}",
          :op_arg  => "(#{op_arg.except(:name).map { |k, v| "#{k}=#{v}" }.join(', ')})",
          :tower   => "EMS(manager_id=#{manager.id})"
        }
      }
    end
  end

  describe "git_repository interaction" do
    let(:auth) { FactoryGirl.create(:embedded_ansible_scm_credential) }
    let(:configuration_script_source) do
      described_class.create!(
        :name           => "foo",
        :scm_url        => "https://example.com/foo.git",
        :authentication => auth
      )
    end

    it "on .create" do
      configuration_script_source

      git_repository = GitRepository.first
      expect(git_repository.name).to eq "foo"
      expect(git_repository.url).to eq "https://example.com/foo.git"
      expect(git_repository.authentication).to eq auth

      expect { configuration_script_source.git_repository }.to_not exceed_query_limit(0)
      expect(configuration_script_source.git_repository_id).to eq git_repository.id
    end

    it "on .new" do
      configuration_script_source = described_class.new(
        :name           => "foo",
        :scm_url        => "https://example.com/foo.git",
        :authentication => auth
      )

      expect(GitRepository.count).to eq 0

      attached_git_repository = configuration_script_source.git_repository

      git_repository = GitRepository.first
      expect(git_repository).to eq attached_git_repository
      expect(git_repository.name).to eq "foo"
      expect(git_repository.url).to eq "https://example.com/foo.git"
      expect(git_repository.authentication).to eq auth

      expect { configuration_script_source.git_repository }.to_not exceed_query_limit(0)
      expect(configuration_script_source.git_repository_id).to eq git_repository.id
    end

    it "errors when scm_url is invalid" do
      expect do
        configuration_script_source.update!(:scm_url => "invalid url")
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "syncs attributes down" do
      configuration_script_source.name = "bar"
      expect(configuration_script_source.git_repository.name).to eq "bar"

      configuration_script_source.scm_url = "https://example.com/bar.git"
      expect(configuration_script_source.git_repository.url).to eq "https://example.com/bar.git"

      configuration_script_source.authentication = nil
      expect(configuration_script_source.git_repository.authentication).to be_nil
    end

    it "persists attributes down" do
      configuration_script_source.update!(:name => "bar")
      expect(GitRepository.first.name).to eq "bar"

      configuration_script_source.update!(:scm_url => "https://example.com/bar.git")
      expect(GitRepository.first.url).to eq "https://example.com/bar.git"

      configuration_script_source.update!(:authentication => nil)
      expect(GitRepository.first.authentication).to be_nil
    end
  end
end
