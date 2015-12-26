require 'yaml'
require 'fileutils'

class ConflictDetector

  def initialize(settings)
    @settings = settings
    @git = Git::Git.new(@settings.repository_name)
  end

  def run
    process_repo
  end

  private

  def should_ignore_branch_by_list?(branch)
    @settings.ignore_branches.include_regex?(branch)
  end

  def should_ignore_branch_by_date?(branch)
    @settings.ignore_branches_modified_days_ago > 0 or return
    branch.last_modified_date < (Date.today - @settings.ignore_branches_modified_days_ago)
  end

  def should_include_branch?(branch)
    !@settings.only_branches.empty? or return true
    @settings.only_branches.include_regex?(branch)
  end

  def should_ignore_conflicts?(conflicts)
    @settings.ignore_conflicts_in_file_paths or return false
    conflicts.reject_regex(@settings.ignore_conflicts_in_file_paths).empty?
  end

  def should_push_merged_branch?(target_branch, source_branch)
    branches = GlobalSettings.push_successful_merges_of[source_branch]
    branches.present? && branches.any? do |regex|
      conflict =~ Regexp.new(regex)
    end
  end

  def get_branch_list()
    branches = @git.get_branch_list

    branches.delete_if do |branch|
      if should_ignore_branch_by_list?(branch)
        Rails.logger.info("Skipping branch #{branch.name}, it is on the ignore list")
        true
      elsif !should_include_branch?(branch)
        Rails.logger.info("Skipping branch #{branch.name}, it is not on the include list")
        true
      elsif should_ignore_branch_by_date?(branch)
        Rails.logger.info("Skipping branch #{branch.name}, it has not been modified in over #{@settings.ignore_branches_modified_days_ago} days")
        true
      else
        false
      end
    end
  end

  def get_conflicts(target_branch, source_branches)
    # get onto the target branch
    @git.execute("checkout #{target_branch.name}")
    @git.execute("reset --hard origin/#{target_branch.name}")

    conflicts = []
    branches_checked = 0
    source_branches.each do |source_branch|
      # break if we have tested enough branches already
      branches_checked += 1
      if GlobalSettings.maximum_branches_to_check && (branches_checked > GlobalSettings.maximum_branches_to_check)
        Rails.logger.warn("WARNING: Checked the maximum number of branches allowed, #{GlobalSettings.maximum_branches_to_check}, exiting early")
        break
      end

      # don't try to merge the branch with itself
      next if target_branch.name == source_branch.name

      Rails.logger.debug("Attempt to merge #{source_branch.name}")
      conflict = @git.detect_conflicts(target_branch.name, source_branch.name)
      unless conflict.present?
        Rails.logger.info("MERGED: #{source_branch.name} can be merged into #{target_branch.name} without conflicts")
        if should_push_merged_branch?(target_branch, source_branch)
          Rails.logger.info("PUSHING: #{target_branch.name} to origin")
          @git.push
        end
      else
        if should_ignore_conflicts?(conflict.conflicting_files)
          Rails.logger.info("MERGED: #{target_branch.name} conflicts with #{source_branch.name}, but all conflicting files are on the ignore list.")
        else
          Rails.logger.info("CONFLICT: #{target_branch.name} conflicts with #{source_branch.name}\nConflicting files:\n#{conflict.conflicting_files}")
          conflicts << conflict
        end
      end
    end

    conflicts
  end

  def process_repo()
    start_time = DateTime.now

    @git.clone_repository(@settings.master_branch_name)

    # get a list of branches and add them to the DB
    get_branch_list.each do |branch|
      Branch.create_from_git_data!(branch)
    end

    # delete branches that were not updated by the git data
    # i.e. they have been deleted from git
    Branch.from_repository(@settings.repository_name).branches_not_updated_since(start_time).destroy_all

    # get the list of branches that are new or have been updated since they were last tested
    untested_branches = Branch.untested_branches
    if untested_branches.empty?
      Rails.logger.info("\nNo branches to process, exiting")
      return
    end
    Rails.logger.info("\nBranches to process: #{untested_branches.join(', ')}")

    tested_pairs = []
    all_branches = Branch.all
    untested_branches.each do |branch|
      Rails.logger.info("\nProcessing target branch: #{branch.name}")

      # exclude combinations we have already tested from the list
      # TODO: Extract into function
      branches_to_test = all_branches.select do |tested_branch|
        if tested_pairs.include?("#{branch.name}:#{tested_branch.name}")
          Rails.logger.debug("Skipping #{tested_branch.name}, already tested this combination")
          false
        elsif branch.name == tested_branch.name
          false
        else
          true
        end
      end

      # check this branch with the others to see if they conflict
      conflicts = get_conflicts(branch, branches_to_test)

      branches_to_test.each do |tested_branch|
        # see if we got a conflict for this branch
        matching_conflicts = conflicts.select do |conflict|
          conflict.contains_branch(tested_branch.name)
        end
        matching_conflicts.size <= 1 or raise "Found more than one conflict for the branch #{tested_branch}!"
        conflict = matching_conflicts[0]

        # record or clear the conflict based on the test result
        unless matching_conflicts.empty?
          Conflict.create!(branch, tested_branch, conflict.conflicting_files, start_time)
        else
          Conflict.resolve!(branch, tested_branch, start_time)
        end

        # record the fact that we tested these branches
        tested_pairs << "#{branch.name}:#{tested_branch.name}"
        tested_pairs << "#{tested_branch.name}:#{branch.name}"
      end

      branch.mark_as_tested!
    end

    # send notifications out
    ConflictsMailer.send_conflict_emails(
        @settings.repository_name,
        start_time,
        Branch.where(name: @settings.suppress_conflicts_for_owners_of_branches),
        @settings.ignore_conflicts_in_file_paths)
  end
end

