
  You are the lead software engineer for a drone-swarm simulation and reinforcement-learning project.                
                                                                                                                       
    Your job is to inspect the existing workspace, preserve the useful parts of GDST, and convert it incrementally into
    a deterministic, headless-capable drone-swarm RL simulator using:                                                  
                                                                                                                       
    * Godot for world simulation, physics, sensors and visualization.                                                  
    * Julia for reinforcement-learning training.                                                                       
    * GDST as the simulator foundation rather than discarding it.                                                      
    * Git commits throughout the work.                                                                                 
                                                                                                                       
    Do not only provide instructions. Modify the repository, run the commands, test the result, fix failures and leave 
    the project in a working state.                                                                                    
                                                                                                                       
    # Workspace                                                                                                        
                                                                                                                       
    The project workspace is:                                                                                          
                                                                                                                       
    ```text                                                                                                            
    /home/charles/Projects/drone-swarm-sim                                                                             
    ```                                                                                                                
                                                                                                                       
    Installed dependencies:                                                                                            
                                                                                                                       
    ```text                                                                                                            
    Godot 4.7.1                                                                                                        
    Julia 1.12.6                                                                                                       
    Git 2.43.0                                                                                                         
    Linux x86-64                                                                                                       
    ```                                                                                                                
                                                                                                                       
    Expected current structure:                                                                                        
                                                                                                                       
    ```text                                                                                                            
    drone-swarm-sim/                                                                                                   
    ├── docs/                                                                                                          
    ├── julia/                                                                                                         
    ├── references/                                                                                                    
    │   └── GDST/                                                                                                      
    ├── simulator/                                                                                                     
    ├── .git/                                                                                                          
    ├── .gitignore                                                                                                     
    └── README.md                                                                                                      
    ```                                                                                                                
                                                                                                                       
    The original GDST repository should already be available at:                                                       
                                                                                                                       
    ```text                                                                                                            
    /home/charles/Projects/drone-swarm-sim/references/GDST                                                             
    ```                                                                                                                
                                                                                                                       
    The `simulator/` directory may contain an early clean Godot prototype. Inspect it before changing anything. Do not 
    assume that previous import or refactoring steps were completed.                                                   
                                                                                                                       
    # Primary project goal                                                                                             
                                                                                                                       
    Create a drone-swarm simulation and reinforcement-learning platform in which:                                      
                                                                                                                       
    1. Godot owns simulation time, physics, collisions, obstacles, sensor generation, communication constraints,       
    scenario logic and visualization.                                                                                  
    2. Julia owns policy networks, rollout collection, optimisation, checkpoints, evaluation and eventually the learned
    world model.                                                                                                       
    3. The Godot simulation can run visually or headlessly.                                                            
    4. Simulation behaviour is deterministic for a fixed seed and fixed action sequence.                               
    5. Rendering is separated from simulation state.                                                                   
    6. Every drone computes its next state from the same old swarm state before any state is committed.                
    7. Julia communicates with Godot through a batched environment API.                                                
    8. The architecture eventually supports centralized training with decentralized execution.                         
                                                                                                                       
    # Important engineering constraints                                                                                
                                                                                                                       
    * Use GDST as the starting codebase.                                                                               
    * Preserve its useful FSYNC compute-then-commit behaviour.                                                         
    * Preserve the original Lifeline implementation as a legacy example or baseline.                                   
    * Do not rewrite the entire application without first understanding it.                                            
    * Do not delete the original implementation until replacement functionality is tested.                             
    * Do not couple simulation speed to tweens, animations, GUI callbacks or rendered frame rate.                      
    * Do not allow Julia to set drone positions directly.                                                              
    * Julia should submit actions; Godot should advance dynamics.                                                      
    * Do not begin with raw four-rotor control.                                                                        
    * Begin with acceleration and yaw-rate commands.                                                                   
    * Use fixed timesteps.                                                                                             
    * Use typed GDScript where practical.                                                                              
    * Avoid unstructured dictionaries for the new physical drone state.                                                
    * Avoid adding unnecessary third-party Godot plugins.                                                              
    * Keep commits focused and descriptive.                                                                            
    * Do not commit `.godot/`, logs, recordings, checkpoints or generated build files.                                 
    * Do not silently ignore errors.                                                                                   
    * Do not claim tests pass unless you executed them.                                                                
    * Never leave the repository with parser errors.                                                                   
    * Document architectural decisions as they are made.                                                               
                                                                                                                       
    # Git safety procedure                                                                                             
                                                                                                                       
    Before modifying code:                                                                                             
                                                                                                                       
    ```bash                                                                                                            
    cd /home/charles/Projects/drone-swarm-sim                                                                          
    git status                                                                                                         
    git log --oneline -5                                                                                               
    ```                                                                                                                
                                                                                                                       
    Preserve any uncommitted user changes. Do not overwrite them.                                                      
                                                                                                                       
    Create a development branch:                                                                                       
                                                                                                                       
    ```bash                                                                                                            
    git switch -c refactor-gdst-for-rl                                                                                 
    ```                                                                                                                
                                                                                                                       
    If that branch already exists, switch to it instead.                                                               
                                                                                                                       
    Create a tagged or committed baseline before substantial refactoring.                                              
                                                                                                                       
    # Phase 1: convert GDST into a deterministic simulation core                                                       
                                                                                                                       
    Phase 1 is the immediate priority. Complete all Phase 1 acceptance tests before proceeding to the Julia bridge.    
                                                                                                                       
    ## Task 1 — Inspect and document the current repository                                                            
                                                                                                                       
    Inspect at least:                                                                                                  
                                                                                                                       
    ```text                                                                                                            
    references/GDST/project.godot                                                                                      
    references/GDST/Core/Drone.gd                                                                                      
    references/GDST/Core/DroneManager.gd                                                                               
    references/GDST/Core/Protocol.gd                                                                                   
    references/GDST/Core/ExecReturn.gd                                                                                 
    references/GDST/Impl/                                                                                              
    references/GDST/Sim/Drone3D.tscn                                                                                   
    references/GDST/Sim/3DPlayground.tscn                                                                              
    references/GDST/Sim/SimulationView.tscn                                                                            
    references/GDST/Sim/Scripts/                                                                                       
    ```                                                                                                                
                                                                                                                       
    Search for:                                                                                                        
                                                                                                                       
    * Tween usage.                                                                                                     
    * `await` usage.                                                                                                   
    * Physics body types.                                                                                              
    * Simulation-step entry points.                                                                                    
    * Drone creation and deletion.                                                                                     
    * Neighbour detection.                                                                                             
    * `Area3D` overlap checks.                                                                                         
    * Protocol selection.                                                                                              
    * Dictionary state keys.                                                                                           
    * GUI dependencies.                                                                                                
    * Timer dependencies.                                                                                              
    * Random-number usage.                                                                                             
    * Main scene configuration.                                                                                        
    * Autoloads.                                                                                                       
    * Godot 4.0 compatibility issues.                                                                                  
                                                                                                                       
    Create:                                                                                                            
                                                                                                                       
    ```text                                                                                                            
    docs/gdst_architecture.md                                                                                          
    ```                                                                                                                
                                                                                                                       
    Document:                                                                                                          
                                                                                                                       
    * Existing scene tree.                                                                                             
    * Existing core classes.                                                                                           
    * How one simulation step currently works.                                                                         
    * How neighbours are determined.                                                                                   
    * Which code is Lifeline-specific.                                                                                 
    * Which code is presentation-specific.                                                                             
    * Which components should be retained, wrapped, refactored or replaced.                                            
    * Any Godot 4.7.1 migration issues found.                                                                          
                                                                                                                       
    Do not begin major refactoring before this document exists.                                                        
                                                                                                                       
    ## Task 2 — Import GDST as the active simulator                                                                    
                                                                                                                       
    Use the contents of `references/GDST` as the simulator foundation.                                                 
                                                                                                                       
    Preserve an existing prototype if one exists:                                                                      
                                                                                                                       
    ```text                                                                                                            
    simulator-clean-prototype/                                                                                         
    ```                                                                                                                
                                                                                                                       
    Do not copy GDST’s internal `.git` directory.                                                                      
                                                                                                                       
    The resulting active Godot project must be located at:                                                             
                                                                                                                       
    ```text                                                                                                            
    /home/charles/Projects/drone-swarm-sim/simulator                                                                   
    ```                                                                                                                
                                                                                                                       
    Ensure:                                                                                                            
                                                                                                                       
    ```text                                                                                                            
    simulator/project.godot                                                                                            
    ```                                                                                                                
                                                                                                                       
    exists.                                                                                                            
                                                                                                                       
    Open or import the project using Godot 4.7.1 and resolve migration issues carefully.                               
                                                                                                                       
    Run:                                                                                                               
                                                                                                                       
    ```bash                                                                                                            
    godot --editor --path simulator                                                                                    
    godot --headless --path simulator --quit-after 5                                                                   
    ```                                                                                                                
                                                                                                                       
    Record all initial errors before fixing them.                                                                      
                                                                                                                       
    Commit the functioning imported baseline separately from later refactors.                                          
                                                                                                                       
    Suggested commit:                                                                                                  
                                                                                                                       
    ```text                                                                                                            
    Import GDST as simulator foundation                                                                                
    ```                                                                                                                
                                                                                                                       
    ## Task 3 — Preserve the synchronous update model                                                                  
                                                                                                                       
    Retain the semantic behaviour:                                                                                     
                                                                                                                       
    ```text                                                                                                            
    observe old swarm state                                                                                            
    → compute every drone’s next state                                                                                 
    → validate all results                                                                                             
    → commit every drone’s new state                                                                                   
    ```                                                                                                                
                                                                                                                       
    No drone may observe a partially updated swarm during one environment step.                                        
                                                                                                                       
    Add automated tests proving this behaviour.                                                                        
                                                                                                                       
    The new implementation may introduce a state snapshot, action array and next-state array, but it must retain       
    synchronous semantics.                                                                                             
                                                                                                                       
    ## Task 4 — Introduce typed physical state                                                                         
                                                                                                                       
    Create a typed physical state abstraction rather than expanding the original state dictionaries indefinitely.      
                                                                                                                       
    A suitable state should include:                                                                                   
                                                                                                                       
    ```text                                                                                                            
    agent_id                                                                                                           
    position                                                                                                           
    velocity                                                                                                           
    orientation or yaw                                                                                                 
    angular velocity or yaw rate                                                                                       
    battery                                                                                                            
    active                                                                                                             
    collided                                                                                                           
    previous_action                                                                                                    
    ```                                                                                                                
                                                                                                                       
    Use a Godot `RefCounted` class, Resource or another well-justified typed representation.                           
                                                                                                                       
    Legacy Lifeline protocol metadata may remain in dictionaries temporarily, but physical state and RL observations   
    must not depend on arbitrary dictionary keys.                                                                      
                                                                                                                       
    Provide explicit serialization methods for:                                                                        
                                                                                                                       
    ```text                                                                                                            
    state → Dictionary                                                                                                 
    Dictionary → state                                                                                                 
    state → packed Float32 representation                                                                              
    ```                                                                                                                
                                                                                                                       
    Add validation for non-finite values.                                                                              
                                                                                                                       
    ## Task 5 — Separate simulation from rendering                                                                     
                                                                                                                       
    The logical simulator must not wait for visual tweens.                                                             
                                                                                                                       
    Implement two layers:                                                                                              
                                                                                                                       
    ```text                                                                                                            
    Simulation state                                                                                                   
        Advances immediately at a fixed timestep.                                                                      
                                                                                                                       
    Rendering state                                                                                                    
        Displays or interpolates the latest simulation state.                                                          
    ```                                                                                                                
                                                                                                                       
    Training/headless mode must:                                                                                       
                                                                                                                       
    * Disable tweens.                                                                                                  
    * Disable labels and expensive debug drawing.                                                                      
    * Avoid waiting for animation completion.                                                                          
    * Advance as fast as possible.                                                                                     
    * Produce the same logical results as visual mode.                                                                 
                                                                                                                       
    Visual mode may interpolate between the previous and latest state, but interpolation must never feed back into     
    simulation.                                                                                                        
                                                                                                                       
    Retain the existing GDST visual appearance when practical.                                                         
                                                                                                                       
    ## Task 6 — Implement simplified deterministic drone dynamics                                                      
                                                                                                                       
    Do not implement raw rotor physics in Phase 1.                                                                     
                                                                                                                       
    Use a high-level continuous action:                                                                                
                                                                                                                       
    ```text                                                                                                            
    [action_x, action_y, action_z, yaw_rate]                                                                           
    ```                                                                                                                
                                                                                                                       
    Each component should be normalized to approximately:                                                              
                                                                                                                       
    ```text                                                                                                            
    [-1, 1]                                                                                                            
    ```                                                                                                                
                                                                                                                       
    Godot converts this into:                                                                                          
                                                                                                                       
    * Desired world-relative or body-relative acceleration.                                                            
    * Desired yaw rate.                                                                                                
    * Velocity changes.                                                                                                
    * Position changes.                                                                                                
    * Collision-aware movement.                                                                                        
                                                                                                                       
    Create configurable parameters for:                                                                                
                                                                                                                       
    ```text                                                                                                            
    physics timestep                                                                                                   
    policy timestep                                                                                                    
    physics substeps per action                                                                                        
    maximum acceleration                                                                                               
    maximum speed                                                                                                      
    maximum yaw rate                                                                                                   
    linear drag                                                                                                        
    gravity behaviour                                                                                                  
    battery usage                                                                                                      
    world bounds                                                                                                       
    ```                                                                                                                
                                                                                                                       
    A reasonable initial configuration is:                                                                             
                                                                                                                       
    ```text                                                                                                            
    physics frequency: 60 Hz                                                                                           
    policy frequency: 20 Hz                                                                                            
    physics substeps per action: 3                                                                                     
    ```                                                                                                                
                                                                                                                       
    The exact values may be adjusted, but document them.                                                               
                                                                                                                       
    For Phase 1, the drone may use hover-compensated acceleration so that the policy does not need to learn basic      
    flight stabilization.                                                                                              
                                                                                                                       
    Do not directly teleport the drone to the requested action position.                                               
                                                                                                                       
    ## Task 7 — Add collisions and a simple world                                                                      
                                                                                                                       
    Provide:                                                                                                           
                                                                                                                       
    * Ground collision.                                                                                                
    * At least one static obstacle.                                                                                    
    * Drone collision shape.                                                                                           
    * World bounds.                                                                                                    
    * Collision event flags.                                                                                           
    * Collision count.                                                                                                 
    * Reset after leaving valid bounds.                                                                                
                                                                                                                       
    Ensure collision results are part of simulator state and not inferred only from rendered transforms.               
                                                                                                                       
    ## Task 8 — Add a scenario-independent simulation API                                                              
                                                                                                                       
    Create a core environment class with responsibilities similar to:                                                  
                                                                                                                       
    ```text                                                                                                            
    configure(config)                                                                                                  
    reset(seed, scenario)                                                                                              
    get_spec()                                                                                                         
    get_observations()                                                                                                 
    apply_actions(actions)                                                                                             
    step()                                                                                                             
    is_terminated()                                                                                                    
    is_truncated()                                                                                                     
    get_rewards()                                                                                                      
    get_info()                                                                                                         
    ```                                                                                                                
                                                                                                                       
    Do not connect Julia yet, but design this as the future environment boundary.                                      
                                                                                                                       
    Support:                                                                                                           
                                                                                                                       
    ```text                                                                                                            
    one drone                                                                                                          
    multiple drones                                                                                                    
    variable active-agent count                                                                                        
    stable agent ordering                                                                                              
    ```                                                                                                                
                                                                                                                       
    Create at least one simple Phase 1 scenario:                                                                       
                                                                                                                       
    ```text                                                                                                            
    WaypointScenario                                                                                                   
    ```                                                                                                                
                                                                                                                       
    It should:                                                                                                         
                                                                                                                       
    * Spawn one or more drones.                                                                                        
    * Spawn a target.                                                                                                  
    * Provide target-relative observations.                                                                            
    * Terminate on success.                                                                                            
    * Truncate after a maximum number of steps.                                                                        
    * Return a simple progress reward.                                                                                 
    * Reset deterministically from a seed.                                                                             
                                                                                                                       
    Keep the original Lifeline scenario available separately.                                                          
                                                                                                                       
    ## Task 9 — Add basic observations and scripted actions                                                            
                                                                                                                       
    Initial per-drone observation should include:                                                                      
                                                                                                                       
    ```text                                                                                                            
    normalized position                                                                                                
    normalized velocity                                                                                                
    yaw representation                                                                                                 
    relative target vector                                                                                             
    distance to target                                                                                                 
    collision flag                                                                                                     
    battery                                                                                                            
    previous action                                                                                                    
    active-agent mask                                                                                                  
    ```                                                                                                                
                                                                                                                       
    For multiple drones, add a minimal nearest-neighbour representation or explicitly defer it to the next milestone.  
                                                                                                                       
    Create scripted or keyboard controllers that use the same action interface intended for Julia.                     
                                                                                                                       
    At minimum provide:                                                                                                
                                                                                                                       
    * Zero-action controller.                                                                                          
    * Random seeded controller.                                                                                        
    * Waypoint proportional controller.                                                                                
                                                                                                                       
    The scripted controller must not modify drone state directly.                                                      
                                                                                                                       
    ## Task 10 — Deterministic seeding                                                                                 
                                                                                                                       
    Create a clear seed flow.                                                                                          
                                                                                                                       
    One reset seed should control:                                                                                     
                                                                                                                       
    * Drone spawn positions.                                                                                           
    * Target position.                                                                                                 
    * Obstacle randomization.                                                                                          
    * Random controller actions.                                                                                       
    * Scenario randomness.                                                                                             
                                                                                                                       
    Avoid global uncontrolled random calls.                                                                            
                                                                                                                       
    Add a deterministic trajectory test:                                                                               
                                                                                                                       
    1. Reset with a fixed seed.                                                                                        
    2. Generate a fixed action sequence.                                                                               
    3. Run a fixed number of steps.                                                                                    
    4. Store or hash the final logical state.                                                                          
    5. Reset and replay.                                                                                               
    6. Confirm that the resulting state matches within a documented tolerance.                                         
                                                                                                                       
    Exact floating-point identity across different hardware is not required, but repeated runs on the current pinned   
    platform should match.                                                                                             
                                                                                                                       
    ## Task 11 — Add headless command-line execution                                                                   
                                                                                                                       
    Support a command resembling:                                                                                      
                                                                                                                       
    ```bash                                                                                                            
    godot --headless --path simulator -- \                                                                             
      --training \                                                                                                     
      --scenario=waypoint \                                                                                            
      --seed=1234 \                                                                                                    
      --agents=4 \                                                                                                     
      --steps=1000                                                                                                     
    ```                                                                                                                
                                                                                                                       
    The exact argument parser may differ.                                                                              
                                                                                                                       
    It must:                                                                                                           
                                                                                                                       
    * Load the simulation.                                                                                             
    * Reset the selected scenario.                                                                                     
    * Run a scripted or seeded-random policy.                                                                          
    * Print a concise summary.                                                                                         
    * Exit successfully.                                                                                               
    * Never require GUI interaction.                                                                                   
                                                                                                                       
    Provide a shell script such as:                                                                                    
                                                                                                                       
    ```text                                                                                                            
    scripts/run_headless_smoke_test.sh                                                                                 
    ```                                                                                                                
                                                                                                                       
    ## Task 12 — Tests                                                                                                 
                                                                                                                       
    Create automated tests or headless test scenes for:                                                                
                                                                                                                       
    * Project startup.                                                                                                 
    * Reset.                                                                                                           
    * Fixed timestep.                                                                                                  
    * Compute-all-before-commit semantics.                                                                             
    * Stable agent ordering.                                                                                           
    * Action clamping.                                                                                                 
    * NaN and infinity rejection.                                                                                      
    * Maximum speed enforcement.                                                                                       
    * Collision reporting.                                                                                             
    * Deterministic replay.                                                                                            
    * Headless execution.                                                                                              
    * Visual simulation state matching logical state.                                                                  
    * Legacy Lifeline scene still opening, when practical.                                                             
                                                                                                                       
    Use built-in Godot scripts or a lightweight test mechanism. Do not add a large test framework unless it provides   
    clear value.                                                                                                       
                                                                                                                       
    ## Task 13 — Documentation                                                                                         
                                                                                                                       
    Update:                                                                                                            
                                                                                                                       
    ```text                                                                                                            
    README.md                                                                                                          
    ```                                                                                                                
                                                                                                                       
    Add:                                                                                                               
                                                                                                                       
    ```text                                                                                                            
    docs/architecture.md                                                                                               
    docs/phase1.md                                                                                                     
    docs/scenario_api.md                                                                                               
    docs/testing.md                                                                                                    
    ```                                                                                                                
                                                                                                                       
    The documentation must include:                                                                                    
                                                                                                                       
    * Installation requirements.                                                                                       
    * How to open the Godot editor.                                                                                    
    * How to run the visual simulator.                                                                                 
    * How to run headlessly.                                                                                           
    * How the synchronous update works.                                                                                
    * Action and observation specifications.                                                                           
    * Determinism limitations.                                                                                         
    * Current project limitations.                                                                                     
    * Phase 2 plan.                                                                                                    
                                                                                                                       
    # Phase 1 acceptance criteria                                                                                      
                                                                                                                       
    Phase 1 is complete only when all of the following are true:                                                       
                                                                                                                       
    1. `simulator/project.godot` opens in Godot 4.7.1 without parser errors.                                           
    2. The original GDST code has been imported and its useful architecture is documented.                             
    3. The original Lifeline implementation is preserved as a legacy scenario or clearly isolated baseline.            
    4. At least one drone can be controlled through acceleration and yaw-rate actions.                                 
    5. Multiple drones use compute-all-then-commit-all synchronous stepping.                                           
    6. Logical simulation does not wait for tweens or GUI animations.                                                  
    7. The simulator runs headlessly.                                                                                  
    8. A fixed seed and fixed action sequence reproduce the same trajectory within tolerance.                          
    9. One generic waypoint scenario runs visually and headlessly.                                                     
    10. Automated smoke tests pass.                                                                                    
    11. The working tree is clean.                                                                                     
    12. All important changes are committed.                                                                           
                                                                                                                       
    Run at least:                                                                                                      
                                                                                                                       
    ```bash                                                                                                            
    cd /home/charles/Projects/drone-swarm-sim                                                                          
                                                                                                                       
    godot --headless --path simulator --quit-after 5                                                                   
                                                                                                                       
    bash scripts/run_headless_smoke_test.sh                                                                            
                                                                                                                       
    git status                                                                                                         
    git log --oneline --decorate -10                                                                                   
    ```                                                                                                                
                                                                                                                       
    Include actual command output in the completion report.                                                            
                                                                                                                       
    # Phase 2: Julia environment bridge                                                                                
                                                                                                                       
    Only begin this after Phase 1 passes.                                                                              
                                                                                                                       
    Create a Julia package inside:                                                                                     
                                                                                                                       
    ```text                                                                                                            
    julia/                                                                                                             
    ```                                                                                                                
                                                                                                                       
    Use a structure resembling:                                                                                        
                                                                                                                       
    ```text                                                                                                            
    julia/                                                                                                             
    ├── Project.toml                                                                                                   
    ├── src/                                                                                                           
    │   ├── DroneSwarmRL.jl                                                                                            
    │   ├── Protocol.jl                                                                                                
    │   └── GodotSwarmEnv.jl                                                                                           
    └── test/                                                                                                          
    ```                                                                                                                
                                                                                                                       
    Implement a local TCP bridge.                                                                                      
                                                                                                                       
    Commands:                                                                                                          
                                                                                                                       
    ```text                                                                                                            
    HELLO                                                                                                              
    GET_SPEC                                                                                                           
    RESET                                                                                                              
    STEP                                                                                                               
    CLOSE                                                                                                              
    ```                                                                                                                
                                                                                                                       
    Requirements:                                                                                                      
                                                                                                                       
    * One network request per whole swarm step, not one request per drone.                                             
    * Batched observations.                                                                                            
    * Batched actions.                                                                                                 
    * Request IDs.                                                                                                     
    * Episode IDs.                                                                                                     
    * Message-length framing.                                                                                          
    * Timeout handling.                                                                                                
    * Invalid-shape rejection.                                                                                         
    * Non-finite action rejection.                                                                                     
    * Clean reconnect behaviour.                                                                                       
    * JSON first for debugging.                                                                                        
    * Protocol designed so binary Float32 payloads can be introduced later.                                            
                                                                                                                       
    The Julia environment should expose operations equivalent to:                                                      
                                                                                                                       
    ```julia                                                                                                           
    reset!(env; seed, scenario, agent_count)                                                                           
    step!(env, actions)                                                                                                
    close(env)                                                                                                         
    ```                                                                                                                
                                                                                                                       
    Add integration tests that start a headless Godot worker, run reset and 1,000 steps, and shut it down.             
                                                                                                                       
    # Phase 3: single-drone PPO                                                                                        
                                                                                                                       
    After the Julia bridge passes:                                                                                     
                                                                                                                       
    * Add `Lux.jl`.                                                                                                    
    * Add the required optimisation and statistics packages.                                                           
    * Add `ReinforcementLearningBase.jl` only where its interface is useful.                                           
    * Implement the PPO training loop explicitly.                                                                      
    * Train one drone on waypoint navigation.                                                                          
    * Add rollout buffers.                                                                                             
    * Add generalized advantage estimation.                                                                            
    * Add checkpointing.                                                                                               
    * Add evaluation on unseen seeds.                                                                                  
    * Add observation normalization.                                                                                   
    * Log reward components separately.                                                                                
                                                                                                                       
    Do not claim successful learning from training return alone. Evaluate on held-out seeds.                           
                                                                                                                       
    # Phase 4: swarm MAPPO                                                                                             
                                                                                                                       
    After single-drone PPO works:                                                                                      
                                                                                                                       
    * Shared decentralized actor.                                                                                      
    * Centralized critic.                                                                                              
    * Stable per-agent masks.                                                                                          
    * Team reward and individual shaping.                                                                              
    * Nearest-neighbour observations.                                                                                  
    * Communication graph.                                                                                             
    * Variable drone counts.                                                                                           
    * Formation scenario.                                                                                              
    * Coverage scenario.                                                                                               
    * Lifeline communication-relay scenario.                                                                           
    * Evaluation on unseen maps and swarm sizes.                                                                       
                                                                                                                       
    # Phase 5: world-aware model                                                                                       
                                                                                                                       
    Only after the model-free baseline works:                                                                          
                                                                                                                       
    * Local occupancy representation.                                                                                  
    * Recurrent actor memory.                                                                                          
    * Neighbour attention or graph message passing.                                                                    
    * Latent observation encoder.                                                                                      
    * Latent transition model.                                                                                         
    * Reward prediction.                                                                                               
    * Collision prediction.                                                                                            
    * Termination prediction.                                                                                          
    * Multi-step prediction evaluation.                                                                                
                                                                                                                       
    Initially use the world model as an auxiliary training objective. Do not immediately rely on imagined rollouts.    
                                                                                                                       
    # Commit strategy                                                                                                  
                                                                                                                       
    Use small commits such as:                                                                                         
                                                                                                                       
    ```text                                                                                                            
    Document existing GDST architecture                                                                                
    Import GDST as active simulator                                                                                    
    Fix Godot 4.7 compatibility                                                                                        
    Add typed physical drone state                                                                                     
    Separate simulation and rendering                                                                                  
    Add deterministic drone dynamics                                                                                   
    Add waypoint scenario                                                                                              
    Add headless simulation runner                                                                                     
    Add Phase 1 deterministic tests                                                                                    
    Document Phase 1 simulator API                                                                                     
    Add Julia TCP environment bridge                                                                                   
    Add Julia-Godot integration tests                                                                                  
    ```                                                                                                                
                                                                                                                       
    Do not squash everything into one commit.                                                                          
                                                                                                                       
    # Required working style                                                                                           
                                                                                                                       
    Operate autonomously.                                                                                              
                                                                                                                       
    When something fails:                                                                                              
                                                                                                                       
    1. Inspect the actual error.                                                                                       
    2. Locate the responsible code.                                                                                    
    3. Apply the smallest justified correction.                                                                        
    4. Re-run the failing test.                                                                                        
    5. Run relevant regression tests.                                                                                  
    6. Commit only after the state is working.                                                                         
                                                                                                                       
    Do not stop merely because GDST was written for an older Godot release.                                            
                                                                                                                       
    Do not replace functioning code solely for stylistic reasons.                                                      
                                                                                                                       
    Do not fabricate successful outputs.                                                                               
                                                                                                                       
    Use comments to explain non-obvious simulation and synchronization decisions, not every line.                      
                                                                                                                       
    # Final completion report                                                                                          
                                                                                                                       
    At the end of each phase, produce:                                                                                 
                                                                                                                       
    ```text                                                                                                            
    1. Summary of completed work                                                                                       
    2. Architecture implemented                                                                                        
    3. Files added                                                                                                     
    4. Files modified                                                                                                  
    5. Commands executed                                                                                               
    6. Test results                                                                                                    
    7. Known limitations                                                                                               
    8. Git commits created                                                                                             
    9. Exact commands for the user to run                                                                              
    10. Next recommended phase                                                                                         
    ```                                                                                                                
                                                                                                                       
    For Phase 1, also include:                                                                                         
                                                                                                                       
    ```text                                                                                                            
    - Visual run command                                                                                               
    - Headless run command                                                                                             
    - Determinism test command                                                                                         
    - Location of the architecture documentation                                                                       
    - Current action-space shape                                                                                       
    - Current observation-space shape                                                                                  
    ```                                                                                                                
                                                                                                                       
    Begin now by inspecting the current workspace and Git state. Preserve existing work, create the development branch,
    document GDST’s architecture, and complete Phase 1 before implementing Julia networking.  
