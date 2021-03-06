require 'yaml'
require 'colored'
require 'highline'
require 'tempfile'

class PT::UI

  GLOBAL_CONFIG_PATH = ENV['HOME'] + "/.pt"
  LOCAL_CONFIG_PATH = Dir.pwd + '/.pt'

  def initialize(args)
    require 'pt/debugger' if ARGV.delete('--debug')
    @io = HighLine.new
    @global_config = load_global_config
    @client = PT::Client.new(@global_config[:api_number])
    @local_config = load_local_config
    @project = @client.get_project(@local_config[:project_id])
    command = args[0].to_sym rescue :my_work
    @params = args[1..-1]
    commands.include?(command.to_sym) ? send(command.to_sym) : help
  end

  def my_work
    title("My Work for #{user_s} in #{project_to_s}")
    stories = @client.get_my_work(@project, @local_config[:user_name])
    PT::TasksTable.new(stories).print @global_config
  end

  def todo
    title("My Work for #{user_s} in #{project_to_s}")
    stories = @client.get_my_work(@project, @local_config[:user_name])
    stories = stories.select { |story| story.current_state == "unscheduled" }
    PT::TasksTable.new(stories).print @global_config
  end

  def started
    # find by a single user
    if @params[0]
        user = find_owner @params[0]
        if user
          stories = @project.stories.all(:current_state => 'started', :owned_by => user)
          PT::TasksTable.new(stories).print @global_config
        end
    else
      # otherwise show them all
      title("Stories started for #{project_to_s}")
      stories = @project.stories.all(:current_state => 'started')
      PT::TasksTable.new(stories).print @global_config
    end
  end

  def list
    if @params[0]
      if @params[0] == "all"
        stories = @client.get_work(@project)
        PT::TasksTable.new(stories).print @global_config
      else
        user = find_owner @params[0]
        if user
          stories = @client.get_my_work(@project, user)
          PT::TasksTable.new(stories).print @global_config
        end
      end
    else
      members = @client.get_members(@project)
      table = PT::MembersTable.new(members)
      user = select("Please select a member to see his tasks.", table).name
      title("Work for #{user} in #{project_to_s}")
      stories = @client.get_my_work(@project, user)
      PT::TasksTable.new(stories).print @global_config
    end
  end

  def recent
    title("Your recent stories from #{project_to_s}")
    stories = @project.stories.all( :id => @local_config[:recent_tasks] )
    PT::MultiUserTasksTable.new(stories).print @global_config
  end

  def label

    task = get_task_from_params "Please select a story to show"
    unless task
      message("No matches found for '#{@params[0]}', please use a valid pivotal story Id")
      return
    end

    if @params[1]
      label = @params[1]
    else
      label = ask("Which label?")
    end

    @client.add_label( @project, task, label );

  end

  def create
    if @params[0]
      name = @params[0]
      owner = find_owner(@params[1]) || find_owner(@params[2]) || @local_config[:user_name]
      requester = @local_config[:user_name]
      task_type = task_type_or_nil(@params[1]) || task_type_or_nil(@params[2]) || 'feature'
    else
      title("Let's create a new task:")
      name = ask("Name for the new task:")
    end

    unless owner
      if ask('Do you want to assign it now? (y/n)').downcase == 'y'
        members = @client.get_members(@project)
        table = PT::MembersTable.new(members)
        owner = select("Please select a member to assign him the task.", table).name
      else
        owner = nil
      end
      requester = @local_config[:user_name]
      task_type = ask('Type? (c)hore, (b)ug, anything else for feature)')
    end

    task_type = case task_type
    when 'c', 'chore'
      'chore'
    when 'b', 'bug'
      'bug'
    else
      'feature'
    end
    result = nil

    # did you do a -m so you can add a description?
    if ARGV.include? "-m" or ARGV.include? "--m"
      editor = ENV.fetch('EDITOR') { 'vi' }
      temp_path = "/tmp/editor-#{ Process.pid }.txt"
      system "#{ editor } #{ temp_path }"
      
      description = File.read(temp_path)
      result = @client.create_task_with_description(@project, name, owner, requester, task_type, description)
      
    else
      result = @client.create_task(@project, name, owner, requester, task_type)
    end
    
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("#{task_type} for #{owner} created: #{result.url}")
    end
  end

  def open
    if @params[0]
      tasks = @client.get_my_work(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      task = table[ @params[0].to_i ]
      congrats("Opening #{task.name}")
    else
      tasks = @client.get_my_open_tasks(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to open it in the browser", table)
    end
    `open #{task.url}`
  end

  def comment
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      comment = @params[1]
      title("Adding a comment to #{task.name}")
    else
      tasks = @client.get_my_work(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to comment it", table)
      comment = ask("Write your comment")
    end
    if @client.comment_task(@project, task, comment)
      congrats("Comment sent, thanks!")
      save_recent_task( task.id )
    else
      error("Ummm, something went wrong.")
    end
  end

  def assign
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      owner = find_owner @params[1]
    else
      title("Tasks for #{user_s} in #{project_to_s}")
      tasks = @client.get_tasks_to_assign(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      task = select("Please select a task to assign it an owner", table)
    end
    
    unless owner
      members = @client.get_members(@project)
      table = PT::MembersTable.new(members)
      owner = select("Please select a member to assign him the task", table).name
    end
    result = @client.assign_task(@project, task, owner)
    
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Task assigned to #{owner}, thanks!")
    end
  end

  def estimate
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      title("Estimating '#{task.name}'")

      if [0,1,2,3].include? @params[1].to_i
        estimation = @params[1]
      end
    else
      tasks = @client.get_my_tasks_to_estimate(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to estimate it", table)
    end

    estimation ||= ask("How many points you estimate for it? (#{@project.point_scale})")
    result = @client.estimate_task(@project, task, estimation)
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Task estimated, thanks!")
    end
  end

  def start
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      title("Starting '#{task.name}'")
    else
      tasks = @client.get_my_tasks_to_start(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to mark it as started", table)
    end
    start_task task
  end

  def finish
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      title("Finishing '#{task.name}'")
    else
      tasks = @client.get_my_tasks_to_finish(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to mark it as finished", table)
    end
    finish_task task
  end

  def deliver
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      title("Delivering '#{task.name}'")
    else
      tasks = @client.get_my_tasks_to_deliver(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to mark it as delivered", table)
    end

    deliver_task task
  end

  def accept
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i
      title("Accepting '#{task.name}'")
    else
      tasks = @client.get_my_tasks_to_accept(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to mark it as accepted", table)
    end
    result = @client.mark_task_as(@project, task, 'accepted')
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Task accepted, hooray!")
    end
  end

  def show
    title("Tasks for #{user_s} in #{project_to_s}")
    task = get_task_from_params "Please select a story to show"
    unless task
      message("No matches found for '#{@params[0]}', please use a valid pivotal story Id")
      return
    end
    result = show_task(task)
  end

  def tasks
    title("Open story tasks for #{user_s} in #{project_to_s}")
    task = get_task_from_params "Please select a story to show pending tasks"
    unless task
      message("No matches found for '#{@params[0]}', please use a valid pivotal story Id")
      return
    end
    story_task = get_open_story_task_from_params(task)

    if story_task.position == -1
      description = ask('Title for new task')
      task.tasks.create(:description => description)
      congrats("New todo task added to \"#{task.name}\"")
    else
      edit_story_task story_task
    end
  end

  # takes a comma separated list of ids and prints the collection of tasks
  def show_condensed
    title("Tasks for #{user_s} in #{project_to_s}")
      tasks = []
    if @params[0]
      @params[0].each_line(',') do |line|
        tasks << @client.get_task_by_id(line.to_i)
      end
      table = PT::TasksTable.new(tasks)
      table.print
    end
  end

  def reject
    title("Tasks for #{user_s} in #{project_to_s}")
    if @params[0]
      tasks = @client.get_my_work(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      task = table[@params[0].to_i]
      title("Rejecting '#{task.name}'")
    else
      tasks = @client.get_my_tasks_to_reject(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      title("Tasks for #{user_s} in #{project_to_s}")
      task = select("Please select a story to mark it as rejected", table)
    end

    if @params[1]
      comment = @params[1]
    else
      comment = ask("Please explain why are you rejecting the task.")
    end

    if @client.comment_task(@project, task, comment)
      result = @client.mark_task_as(@project, task, 'rejected')
      congrats("Task rejected, thanks!")
    else
      error("Ummm, something went wrong.")
    end
  end

  def done
    if @params[0]
      task = task_by_id_or_pt_id @params[0].to_i

      #we need this for finding again later
      task_id = task.id

      if !@params[1] && task.estimate == -1
        error("You need to give an estimate for this task")
        return
      end

      if @params[1] && task.estimate == -1
          if [0,1,2,3].include? @params[1].to_i
            estimate_task(task, @params[1].to_i)
          end
          if @params[2]
            task = task_by_id_or_pt_id task_id
            @client.comment_task(@project, task, @params[2])
          end
      else
        @client.comment_task(@project, task, @params[1]) if @params[1]
      end

      task = task_by_id_or_pt_id task_id
      start_task task

      task = task_by_id_or_pt_id task_id
      finish_task task

      task = task_by_id_or_pt_id task_id
      deliver_task task
    end
  end

  def estimate_task task, difficulty
    result = @client.estimate_task(@project, task, difficulty)
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Task estimated, thanks!")
    end
  end

  def start_task task
    result = @client.mark_task_as(@project, task, 'started')
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Task started, go for it!")
    end
  end

  def finish_task task
    if task.story_type == 'chore'
      result = @client.mark_task_as(@project, task, 'accepted')
    else
      result = @client.mark_task_as(@project, task, 'finished')
    end
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Another task bites the dust, yeah!")
    end
  end

  def deliver_task task
    return if task.story_type == 'chore'

    result = @client.mark_task_as(@project, task, 'delivered')
    error(result.errors.errors) if result.errors.any?
    if result.errors.any?
      error(result.errors.errors)
    else
      congrats("Task delivered, congrats!")
    end
  end

  def find
    if (story_id = @params[0].to_i).nonzero?
      if task = task_by_id_or_pt_id(@params[0].to_i)
        return show_task(task)
      else
        message("Task not found by id (#{story_id}), falling back to text search")
      end
    end

    if @params[0]
      tasks = @client.get_my_work(@project, @local_config[:user_name])
      matched_tasks = tasks.select do |story_task|
        story_task.name.downcase.index(@params[0]) && story_task.current_state != 'delivered'
      end

      matched_tasks.each do |story_task|
        title("--- [#{(tasks.index story_task) + 1 }] -----------------")
        show_task(story_task)
      end
      message("No matches found for '#{@params[0]}'") if matched_tasks.empty?
    else
      message("You need to provide a substring for a tasks title.")
    end
  end

  def updates
    activities = @client.get_activities(@project, @params[0])
    tasks = @client.get_my_work(@project, @local_config[:user_name])
    title("Recent Activity on #{project_to_s}")
    activities.each do |activity|
      show_activity(activity, tasks)
    end
  end


  def help
    if ARGV[0] && ARGV[0] != 'help'
      message("Command #{ARGV[0]} not recognized. Showing help.")
    end

    title("Command line usage for pt #{PT::VERSION}")
    puts("pt                                         # show all available tasks")
    puts("pt todo      <owner>                       # show all unscheduled tasks")
    puts("pt started   <owner>                       # show all started stories")
    puts("pt create    [title] <owner> <type> -m     # create a new task (and include description ala git commit)")
    puts("pt show      [id]                          # shows detailed info about a task")
    puts("pt tasks     [id]                          # manage tasks of story")
    puts("pt open      [id]                          # open a task in the browser")
    puts("pt assign    [id] <owner>                  # assign owner")
    puts("pt comment   [id] [comment]                # add a comment")
    puts("pt label     [id] [label]                  # add a label")
    puts("pt estimate  [id] [0-3]                    # estimate a task in points scale")
    puts("pt start     [id]                          # mark a task as started")
    puts("pt finish    [id]                          # indicate you've finished a task")
    puts("pt deliver   [id]                          # indicate the task is delivered");
    puts("pt accept    [id]                          # mark a task as accepted")
    puts("pt reject    [id] [reason]                 # mark a task as rejected, explaining why")
    puts("pt done      [id]  <0-3> <comment>         # lazy mans finish task, opens, assigns to you, estimates, finish & delivers")
    puts("pt find      [query]                       # looks in your tasks by title and presents it")
    puts("pt list      [owner] or all                # list all tasks for another pt user")
    puts("pt updates   [number]                      # shows number recent activity from your current project")
    puts("pt recent                                  # shows stories you've recently shown or commented on with pt")
    puts("")
    puts("All commands can be run entirely without arguments for a wizard based UI. Otherwise [required] <optional>.")
    puts("Anything that takes an id will also take the num (index) from the pt command.")
  end

  protected

  def commands
    (public_methods - Object.public_methods).map{ |c| c.to_sym}
  end

  # Config

  def load_global_config

    # skip global config if env vars are set
    if ENV['PIVOTAL_EMAIL'] and ENV['PIVOTAL_API_KEY']
      config = {
        :email => ENV['PIVOTAL_EMAIL'],
        :api_number => ENV['PIVOTAL_API_KEY']
      }
      return config
    end

    config = YAML.load(File.read(GLOBAL_CONFIG_PATH)) rescue {}
    if config.empty?
      message "I can't find info about your Pivotal Tracker account in #{GLOBAL_CONFIG_PATH}."
      while !config[:api_number] do
        config[:email] = ask "What is your email?"
        password = ask_secret "And your password? (won't be displayed on screen)"
        begin
          config[:api_number] = PT::Client.get_api_token(config[:email], password)
        rescue PT::InputError => e
          error e.message + " Please try again."
        end
      end
      congrats "Thanks!",
               "Your API id is " + config[:api_number],
               "I'm saving it in #{GLOBAL_CONFIG_PATH} so you don't have to log in again."
      save_config(config, GLOBAL_CONFIG_PATH)
    end
    config
  end

  def get_local_config_path
    # If the local config path does not exist, check to see if we're in a git repo
    # And if so, try the top level of the checkout
    if (!File.exist?(LOCAL_CONFIG_PATH) && system('git rev-parse 2> /dev/null'))
      return `git rev-parse --show-toplevel`.chomp() + '/.pt'
    else
      return LOCAL_CONFIG_PATH
    end
  end

  def load_local_config
    check_local_config_path
    config = YAML.load(File.read(get_local_config_path())) rescue {}

    if ENV['PIVOTAL_PROJECT_ID']

      config[:project_id] = ENV['PIVOTAL_PROJECT_ID']

      project = @client.get_project(config[:project_id])
      config[:project_name] = project.name

      membership = @client.get_membership(project, @global_config[:email])
      config[:user_name], config[:user_id], config[:user_initials] = membership.name, membership.id, membership.initials
      save_config(config, get_local_config_path())

    end

    if config.empty?
      message "I can't find info about this project in #{get_local_config_path()}"
      projects = PT::ProjectTable.new(@client.get_projects)
      project = select("Please select the project for the current directory", projects)
      config[:project_id], config[:project_name] = project.id, project.name
      project = @client.get_project(project.id)
      membership = @client.get_membership(project, @global_config[:email])
      config[:user_name], config[:user_id], config[:user_initials] = membership.name, membership.id, membership.initials
      congrats "Thanks! I'm saving this project's info",
               "in #{get_local_config_path()}: remember to .gitignore it!"
      save_config(config, get_local_config_path())
    end
    config
  end

  def check_local_config_path
    if GLOBAL_CONFIG_PATH == get_local_config_path()
      error("Please execute .pt inside your project directory and not in your home.")
      exit
    end
  end

  def save_config(config, path)
    File.new(path, 'w') unless File.exists?(path)
    File.open(path, 'w') {|f| f.write(config.to_yaml) }
  end

  # I/O

  def split_lines(text)
    text.respond_to?(:join) ? text.join("\n") : text
  end

  def title(*msg)
    puts "\n#{split_lines(msg)}".bold
  end

  def congrats(*msg)
    puts "\n#{split_lines(msg).green.bold}"
  end

  def message(*msg)
    puts "\n#{split_lines(msg)}"
  end

  def compact_message(*msg)
    puts "#{split_lines(msg)}"
  end

  def error(*msg)
    puts "\n#{split_lines(msg).red.bold}"
  end

  def select(msg, table)
    if table.length > 0
      begin
        table.print @global_config
        row = ask "#{msg} (1-#{table.length}, 'q' to exit)"
        quit if row == 'q'
        selected = table[row]
        error "Invalid selection, try again:" unless selected
      end until selected
      selected
    else
      table.print @global_config
      message "Sorry, there are no options to select."
      quit
    end
  end

  def quit
    message "bye!"
    exit
  end

  def ask(msg)
    @io.ask("#{msg.bold}")
  end

  def ask_secret(msg)
    @io.ask("#{msg.bold}"){ |q| q.echo = '*' }
  end

  def user_s
    "#{@local_config[:user_name]} (#{@local_config[:user_initials]})"
  end

  def project_to_s
    "Project #{@local_config[:project_name].upcase}"
  end

  def task_type_or_nil query
    if (["feature", "bug", "chore"].index query)
      return query
    end
    nil
  end

  def task_by_id_or_pt_id id
    if id < 1000
      tasks = @client.get_my_work(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      table[id]
    else 
      @client.get_task_by_id id
    end
  end

  def find_task query
    members = @client.get_members(@project)
    members.each do | member |
      if member.name.downcase.index query
        return member.name
      end
    end
    nil
  end

  def find_owner query
    if query
      member = @client.get_member(@project, query)
      return member ? member.name : nil
    end
    nil
  end

  def show_task(task)
    title task.name.green
    estimation = [-1, nil].include?(task.estimate) ? "Unestimated" : "#{task.estimate} points"
    message "#{task.current_state.capitalize} #{task.story_type} | #{estimation} | Req: #{task.requested_by} | Owns: #{task.owned_by} | Id: #{task.id}"

    if (task.labels)
      message "Labels: " + task.labels.split(',').join(', ')
    end
    message task.description unless task.description.nil? || task.description.empty?
    message "View on pivotal: #{task.url}"

    if task.tasks
      task.tasks.all.each{ |t| compact_message "- #{t.complete ? "(done) " : "(pend)"} #{t.description}" }
    end

    # attachments on a note come through with the same description as the note
    # to prevent the same update from showing multiple times, arrange by description for later lookup
    attachment_match = Hash.new()
    task.attachments.each do |a| 
      unless attachment_match[ a.description ]
          attachment_match[ a.description ] = Array.new()
      end

      attachment_match[ a.description ].push( a );
    end

    task.notes.all.each do |n| 
      message "#{n.author.yellow}: #{n.text}"
      # print attachements for this note
      if attachment_match[ n.text ]
        message "Attachments".bold
        attachment_match[ n.text ].each{ |a| message "#{a.filename} #{a.url}" }
        attachment_match.delete(n.text)
      end
    end

    task.attachments.each do |a| 
      # skip attachments already printed as part of a note
      if attachment_match[ a.description ]
        message "#{a.uploaded_by.yellow} uploaded: \"#{a.description && a.description.empty? ? "#{a.filename}" : "#{a.description} (#{a.filename})" }\" #{a.url}"
      end
    end

    save_recent_task( task.id )

  end


  def show_activity(activity, tasks)
    story_id = activity.stories.first.id
    task_id = nil
    tasks.each do |story|
      if story_id == story.id
        task_id = tasks.index(story)
      end
    end
    message("#{activity.description} [#{task_id}]")
  end

  def get_open_story_task_from_params(task)
    title "Pending tasks for '#{task.name}'"
    task_struct = Struct.new(:description, :position)

    pending_tasks = [
      task_struct.new('<< Add new task >>', -1)
    ]

    task.tasks.all.each{ |t| pending_tasks << t unless t.complete }
    table = PT::TodoTaskTable.new(pending_tasks)
    todo_task = select("Pick task to edit, 1 to add new task", table)
  end

  def get_task_from_params(prompt)
    if @params[0]
      task = task_by_id_or_pt_id(@params[0].to_i)
    else
      tasks = @client.get_my_work(@project, @local_config[:user_name])
      table = PT::TasksTable.new(tasks)
      task = select(prompt, table)
    end
  end
  
  def edit_story_task(story_task)
    action_class = Struct.new(:action, :key)

    table = PT::ActionTable.new([
      action_class.new('Complete', :complete),
      action_class.new('Delete', :delete),
      action_class.new('Edit', :edit)
      # Move?
    ])
    action_to_execute = select('What to do with todo?', table)

    case action_to_execute.key
    when :complete then
      story_task.update(:complete => true)
      congrats('Todo task completed!')
    when :delete then
      story_task.delete
      congrats('Todo task removed')
    when :edit then
      new_description = ask('New task description')
      story_task.update(:description => new_description)
      congrats("Todo task changed to: \"#{story_task.description}\"")
    end
  end

  def save_recent_task( task_id )
    # save list of recently accessed tasks
    unless (@local_config[:recent_tasks])
      @local_config[:recent_tasks] = Array.new();
    end
    @local_config[:recent_tasks].unshift( task_id )
    @local_config[:recent_tasks] = @local_config[:recent_tasks].uniq()
    if @local_config[:recent_tasks].length > 10
      @local_config[:recent_tasks].pop()
    end
    save_config( @local_config, get_local_config_path() )
  end

end
