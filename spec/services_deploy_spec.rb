require 'spec_helper'

describe "Deploying an application with services" do
  describe "a deploy without ey_config" do
    describe "with services" do
      before do
        deploy_test_application('no_ey_config') do |deployer|
          @shared_services_file = deployer.config.paths.shared_config.join('ey_services_config_deploy.yml')
          @services_yml = {"servicio" => {"foo" => "bar"}}.to_yaml
          deployer.mock_services_setup!("echo '#{@services_yml}' > #{@shared_services_file}")
        end
      end

      it "warns about missing ey_config" do
        read_stderr.should include("WARNING: Gemfile.lock does not contain ey_config")
      end
    end

    describe "without services" do
      before do
        deploy_test_application('no_ey_config')
      end

      it "works without warnings" do
        read_output.should_not =~ /WARNING/
      end
    end
  end

  describe "deploy with invalid yaml ey_services_config_deploy" do
    before do
      deploy_test_application do |deployer|
        @shared_services_file    = deployer.config.paths.shared_config.join('ey_services_config_deploy.yml')
        @symlinked_services_file = deployer.config.paths.active_release_config.join('ey_services_config_deploy.yml')
        @invalid_services_yml = "42"
        deployer.mock_services_setup!("echo '#{@invalid_services_yml}' > #{@shared_services_file}")
      end
    end

    it "works without warning" do
      @shared_services_file.should exist
      @shared_services_file.should_not be_symlink
      @shared_services_file.read.should == "#{@invalid_services_yml}\n"

      @symlinked_services_file.should exist
      @symlinked_services_file.should be_symlink
      @shared_services_file.read.should == "#{@invalid_services_yml}\n"

      read_output.should_not =~ /WARNING/
    end
  end

  describe "a succesful deploy" do
    before do
      deploy_test_application do |deployer|
        @shared_services_file    = deployer.config.paths.shared_config.join('ey_services_config_deploy.yml')
        @symlinked_services_file = deployer.config.paths.active_release_config.join('ey_services_config_deploy.yml')
        @services_yml = {"servicio" => {"foo" => "bar"}}.to_yaml

        deployer.mock_services_setup!("echo '#{@services_yml}' > #{@shared_services_file}")
      end
    end

    it "creates and symlinks ey_services_config_deploy.yml" do
      @shared_services_file.should exist
      @shared_services_file.should_not be_symlink
      @shared_services_file.read.should == "#{@services_yml}\n"

      @symlinked_services_file.should exist
      @symlinked_services_file.should be_symlink
      @shared_services_file.read.should == "#{@services_yml}\n"

      read_output.should_not =~ /WARNING/
    end

    describe "followed by a deploy that can't find the command" do
      before do
        redeploy_test_application do |deployer|
          deployer.mock_services_command_check!("which nonexistatncommand")
        end
      end

      it "silently fails" do
        @shared_services_file.should exist
        @shared_services_file.should_not be_symlink
        @shared_services_file.read.should == "#{@services_yml}\n"

        @symlinked_services_file.should exist
        @symlinked_services_file.should be_symlink
        @shared_services_file.read.should == "#{@services_yml}\n"

        read_output.should_not =~ /WARNING/
      end

    end

    describe "followed by a deploy that fails to fetch services" do
      it "logs a warning and symlinks the existing config file when there is existing services file" do
        redeploy_test_application do |deployer|
          deployer.mock_services_setup!("notarealcommandsoitwillexitnonzero")
        end
        @shared_services_file.should exist
        @shared_services_file.should_not be_symlink
        @shared_services_file.read.should == "#{@services_yml}\n"

        @symlinked_services_file.should exist
        @symlinked_services_file.should be_symlink
        @shared_services_file.read.should == "#{@services_yml}\n"

        read_output.should include('WARNING: External services configuration not updated')
      end

      it "does not log a warning or symlink a config file when there is no existing services file" do
        redeploy_test_application do |deployer|
          deployer.mock_services_setup!("notarealcommandsoitwillexitnonzero")
          @shared_services_file.delete
        end

        @shared_services_file.should_not exist
        @symlinked_services_file.should_not exist

        read_output.should_not =~ /WARNING/
      end

    end

    describe "followed by another successfull deploy" do
      before do
        redeploy_test_application do |deployer|
          @services_yml = {"servicio" => {"foo" => "bar2"}}.to_yaml
          deployer.mock_services_setup!("echo '#{@services_yml}' > #{@shared_services_file}")
        end
      end

      it "replaces the config with the new one (and symlinks)" do
        @shared_services_file.should exist
        @shared_services_file.should_not be_symlink
        @shared_services_file.read.should == "#{@services_yml}\n"

        @symlinked_services_file.should exist
        @symlinked_services_file.should be_symlink
        @shared_services_file.read.should == "#{@services_yml}\n"

        read_output.should_not =~ /WARNING/
      end
    end

  end

end
