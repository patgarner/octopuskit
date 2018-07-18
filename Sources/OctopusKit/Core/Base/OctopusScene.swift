//
//  OctopusScene.swift
//  OctopusKit
//
//  Created by ShinryakuTako@invadingoctopus.io on 2014-10-15
//  Copyright © 2018 Invading Octopus. Licensed under Apache License v2.0 (see LICENSE.txt)
//

// TODO: Tests
// CHECK: Implement a cached list of entities for each component type?

// ℹ️ DESIGN: Pause/unpause should be handled by scene code rather than `OctopusGameController` or `OctopusGameState`, as the scene may be automatically paused by the system when the player receives a call or pulls up the iOS Control Center, for example, but that does not necessarily mean that the GAME has entered a different GAME STATE.
// However, if the player manually pauses, then the scene may signal the `OctopusGameController` to enter a "Paused" state, which may or may not then cause a scene transition.

// 🙁 NOTE: This is a large class, but we cannot break it up into multiple files because "Overriding non-@objc declarations from extensions is not supported" as of 2018/03, and other issues with organizing code via extensions: https://github.com/realm/SwiftLint/issues/1767

import SpriteKit
import GameplayKit

/// A protocol for types that control game state transitions and scene presentation based on input from the current scene, such as `OctopusSceneController`.
public protocol OctopusSceneDelegate: class {
    
    /// Notifies the current `OctopusGameState` of the `OctopusGameController` state machine. The state's logic should decide how to interpret the "completion" of a scene and which state to transition to, if any.
    func octopusSceneDidFinish(_ scene: OctopusScene)
    
    /// Notifies the current `OctopusGameState` of the `OctopusGameController` state machine. The state's logic should decide which state should be the "next" state and whether to transition.
    ///
    /// - Returns: `true` if the `OctopusGameController` did change its state, or `false` if the state could not be changed or if there was no "next" state.
    @discardableResult func octopusSceneDidChooseNextGameState(_ scene: OctopusScene) -> Bool
    
    /// Notifies the current `OctopusGameState` of the `OctopusGameController` state machine. The state's logic should decide which state should be the "previous" state and whether to transition.
    ///
    /// - Returns: `true` if the `OctopusGameController` did change its state, or `false` if the state could not be changed or if there was no "previous" state.
    @discardableResult func octopusSceneDidChoosePreviousGameState(_ scene: OctopusScene) -> Bool
    
    /// Notifies the current `OctopusGameState` of the `OctopusGameController` state machine. The state's logic should decide whether the requested transition is valid.
    ///
    /// - Returns: `true` if the `OctopusGameController` did change its state, or `false` if the state could not be changed.
    @discardableResult func octopusScene(_ scene: OctopusScene,
                      didRequestGameStateClass stateClass: OctopusGameState.Type) -> Bool
    
    /// Requests the scene controller to present the scene with the specified filename, without changing the current game state.
    func octopusScene(_ outgoingScene: OctopusScene,
                      didRequestTransitionTo nextSceneFileName: String,
                      withTransition transition: SKTransition?)
    
    /// Requests the scene controller to present the scene of the specified class, without changing the current game state.
    func octopusScene(_ outgoingScene: OctopusScene,
                      didRequestTransitionTo nextSceneClass: OctopusScene.Type,
                      withTransition transition: SKTransition?)
}

// The top-level unit of visual content in a game. Contains components grouped by entities to represent visual and behavorial elements in the scene. Manages component systems to update components in a deterministic order every frame.
///
/// Includes an entity to represent the scene itself.
public class OctopusScene: SKScene,
    OctopusEntityContainer,
    OctopusGameStateDelegate,
    OctopusEntityDelegate,
    OctopusSubsceneDelegate,
    SKPhysicsContactDelegate,
    TouchEventComponentCompatible
{
    // MARK: - Properties
    
    // MARK: Constants
    
    /// The value to clamp `updateTimeDelta` to, to avoid spikes in frame processing.
    public static let updateTimeDeltaMaximum: TimeInterval = 1.0 / 60.0 // CHECK: What if we want more than 60 FPS? // CREDIT: Apple DemoBots sample
    
    // MARK: Timekeeping
    
    /// Updated in `OctopusScene.update(_:)` every frame. May be used for implementing time-based behavior and effects.
    ///
    /// - NOTE: Not checked for overflow, to increase performance.
    public fileprivate(set) var secondsElapsedSinceMovedToView: TimeInterval = 0
    
    /// The number of the frame being rendered. The count of frames rendered so far, minus 1.
    ///
    /// Incremeted at the beginning of every `update(_:)` call. Used for logging and debugging.
    ///
    /// - NOTE: This property actually denotes the number of times the 'update(_:)' method has been called so far. The actual beginning of a "frame" may happen outside the 'update(_:)' method and may not align with the mutation of this property. 
    public fileprivate(set) var currentFrameNumber: UInt64 = 0
    
    /// Updated in `OctopusScene.update(_:)` every frame.
    public fileprivate(set) var updateTimeDelta: TimeInterval = 0
    
    /// Updated in `OctopusScene.update(_:)` every frame.
    public fileprivate(set) var lastUpdateTime: TimeInterval? // CHECK: Should this be optional?
    
    /// Keeps track of the time when the game was paused, so that game elements can resume updating from that time when the game is resumed, instead of at the scene's time which will continue incrementing in every `OctopusScene.update(_:)`.
    public fileprivate(set) var pausedAtTime: TimeInterval?
    
    // MARK: State & Flags
    
    /// Set to `true` after `prepareContents()` is called.
    public fileprivate(set) var didPrepareContents = false
    
    /// Set to `true` when the game is automatically paused by the system, such as when switching to another app or receiving a call.
    ///
    /// Modified during `OctopusAppDelegate.applicationDidBecomeActive(_:)` and `OctopusAppDelegate.applicationWillResignActive(_:)`
    public fileprivate(set) var isPausedBySystem = false
    
    /// Set to `true` when the game is presenting a modal user interface that is waiting for the player's input, while putting the game's action on hold.
    public fileprivate(set) var isPausedBySubscene = false
    
    /// Set to `true` when the game is paused by the player, as opposed to being paused by the system, to display an in-game pause state without affecting actions etc.
    ///
    /// Modified via `pauseByPlayer()` and `unPauseByPlayer()`
    public fileprivate(set) var isPausedByPlayer = false

    /// An array of "subscenes" that display self-contained content in an overlay while pausing the main scene, such as pause-effects, modal UI, cutscenes or minigames.
    ///
    /// This is a stack; if there is more than one subscene, only the most-recently-added subscene is updated, and subscenes must be dismissed in a last-in, first-out order.
    public fileprivate(set) var subscenes: [OctopusSubscene] = []
    
    /// Set to `true` for a single frame after the scene presents a subscene.
    ///
    /// Components can observe this flag to modify or halt their behavior during or after subscene transitions.
    public fileprivate(set) var didPresentSubsceneThisFrame: Bool = false
    
    /// Set to `true` for a single frame after the scene dismisses a subscene.
    ///
    /// Components can observe this flag to modify or halt their behavior during or after subscene transitions.
    public fileprivate(set) var didDismissSubsceneThisFrame: Bool = false
    
    // MARK: Entities & Components
    
    public fileprivate(set) lazy var entities = Set<GKEntity>()
    
    /// Used for deferring the removal of entities, since modifying the list of entities during a frame update may cause an exception/crash, because of mutating the entities collection while it is being enumerated during the update.
    ///
    /// Since this is a `Set`, it prevents entities from being added more than once.
    public var entitiesToRemoveOnNextUpdate = Set<GKEntity>()
    
    /// The primary array of component systems for this scene. Determines the order in which components of all entities must be updated every frame.
    ///
    /// Component systems are in an `Array` instead of a `Set` because a deterministic order of updates is important for proper game functionality. Further arrays may be created by subclass if more groupings of related systems are required. The `Array+OctopusComponentSystem` extension contains helper methods to assist with managing arrays of systems.
    ///
    /// - Important: `OctopusScene` does not update component systems by default, as each game may have its specific logic for updating systems in relation to the paused/unpaused state, etc.
    ///
    /// - Important: The `OctopusScene` subclass must call `updateSystems(in:deltaTime:)` at some point in the `update(_ currentTime: TimeInterval)` method, usually after handling pause/unpause logic.
    ///
    /// - Important: Adding a system does not automatically register the components from any of the scene's existing entities. Call either `self.componentSystems.addComponents(foundIn:)` to register components from a single entity, or `addAllComponentsFromAllEntities(to:)` to register components from all entities.
    public lazy var componentSystems = [OctopusComponentSystem]()
    
    // MARK: Other
    
    /// The object which controls scene and game state transitions on behalf of the current scene. Generally the `OctopusSceneController`.
    public var octopusSceneDelegate: OctopusSceneDelegate?
    
    /// The list of pathfinding graph objects managed by the scene.
    public var graphs: [String : GKGraph] = [:]
    
    /// Debugging information.
    public override var description: String {
        return "\"\(name == nil ? "" : name!)\" frame = \(frame) size = \(size) anchor = \(anchorPoint) view.frame.size = \(String(optional: view?.frame.size))"
    }
    
    // MARK: - Life Cycle
    
    public required override init(size: CGSize) {
        // Required so that it may be constructed by metatype values, e.g. `sceneClass.init(size:)`
        // CHECK: Still necessary?
        super.init(size: size)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        // CHECK: Should we `fatalError()` here? // fatalError("init(coder:) has not been implemented")
    }
    
    public override func sceneDidLoad() {
        OctopusKit.logForFramework.add("\(self)")
        super.sceneDidLoad()
        
        // Create and add the entity that represents the scene itself.
        
        if self.entity == nil {
            createSceneEntity()
        }
        
        // CHECK: Should this be moved to `didMove(to:)`?
        self.lastUpdateTime = 0 // CHECK: nil?
    }
    
    /// An abstract method called by `OctopusSceneController` before the scene is presented in a view. Override this in a subclass to set up scaling etc. before the scene displays any content.
    ///
    /// - Important: This method has to be called manually (e.g. from the `SKView`'s view controller) before presenting the scene. It is not invoked by the system and is *not* guaranteed to be called.
    public func willMove(to view: SKView) {}
    
    /// Calls `prepareContents()` which may be used by a subclass to create the scene's contents, then adds all components from each entity in the `entities` set to the relevant systems in the `componentSystems` array. If overriden then `super` must be called for proper initialization of the scene.
    public override func didMove(to: SKView) {
        // CHECK: Should this be moved to `sceneDidLoad()`?
        OctopusKit.logForFramework.add("name = \"\(name ?? "")\", size = \(size), view.frame.size = \(to.frame.size), scaleMode = \(scaleMode.rawValue)")
        
        secondsElapsedSinceMovedToView = 0
        
        if !didPrepareContents {
            prepareContents()
            // addAllComponentsFromAllEntities(to: self.componentSystems) // CHECK: Necessary? Should we just rely on OctopusEntityDelegate?
            didPrepareContents = true // Take care of this flag here so that subclass does not have to do so in `prepareContents()`.
        }
        
        currentFrameNumber = 1 // Set the frame counter to 1 here because it is incremented in `didFinishUpdate()`, so that logs correctly say the first frame number during the first `update(_:)` method. ⚠️ NOTE: There is still a call to `OctopusSceneController-Universal.viewWillLayoutSubviews()` after this, before the first `update(_:)`. CHECK: Fix?
    }
    
    /// Creates an entity to represent the scene itself (the root node.)
    ///
    /// This entity may incorporate components to display top-level visual content, such as the user interface or head-up display (HUD), and manage scene-wide subsystems such as input.
    fileprivate func createSceneEntity() {
        // BUG: Setting an `SKScene`'s entity directly with `GKEntity()` causes the scene's entity to remain `nil`, as of 2017/10/13.
        
        // Warn if the scene already has an entity representing it.
        
        if let existingEntity = self.entity {
            OctopusKit.logForErrors.add("\(self) already has an entity: \(existingEntity)")
            // CHECK: Remove the existing entity here, or exit the method here?
        }
        
        // Create an entity to represent the scene itself, with an `SpriteKitComponent` and `SpriteKitSceneComponent`.
        
        let sceneEntity = OctopusEntity(name: self.name, node: self) // NOTE: `node: self` adds a `SpriteKitComponent`.
        sceneEntity.addComponent(SpriteKitSceneComponent(scene: self))
        self.entity = sceneEntity
        addEntity(sceneEntity)
        
        assert(self.entity === sceneEntity, "Could not set scene's entity")
    }
    
    /// An abstract method that is called after the scene is presented in a view. To be overriden by a subclass to prepare the scene's content, and set up entities, components and component systems.
    ///
    /// Called from `didMove(to:)`. Call `super.prepareContents()` to include a log entry.
    ///
    /// - Important: Setup the list of component systems for this scene here, using `componentSystems.createSystems(forClasses:)`.
    ///
    /// - Note: If the scene requires the global `OctopusKit.shared.gameController.entity`, add it manually after setting up the component systems, so that the global components may be registered with this scene's systems.
    ///
    /// - Note: A scene may choose to perform the tasks of this method in `gameControllerDidEnterState(_:from:)` instead.
    public func prepareContents() {
        OctopusKit.logForFramework.add()
    }
    
    public override func didChangeSize(_ oldSize: CGSize) {
        // CHECK: This is seemingly always called after `init`, before `sceneDidLoad()`, even when the `oldSize` and current `size` are the same.
        super.didChangeSize(oldSize)
        OctopusKit.logForFramework.add("\(self) — oldSize = \(oldSize) → \(self.size)")
    }
    
    /// By default, removes all entities from the scene when it is no longer in a view, so that the scene may be deinitialized and free up device memory.
    ///
    /// To prevent this behavior, for example in cases where a scene is expected to be presented again and should remain in memory, override this method.
    public override func willMove(from view: SKView) {
        OctopusKit.logForFramework.add()
        super.willMove(from: view)
        
        // CHECK: Should we delay the teardown of an outgoing scene to prevent any performance hiccups in the incoming scene?
        
        for entity in self.entities {
            removeEntity(entity)
        }
    }
    
    deinit {
        OctopusKit.logForFramework.add("\"\(String(optional: self.name))\" secondsElapsedSinceMovedToView = \(String(optional: secondsElapsedSinceMovedToView)), lastUpdateTime = \(String(optional: lastUpdateTime))")
    }
    
    // MARK: - Game State
    
    /// Called by `OctopusGameState`. To be overriden by a subclass if this same scene is used for different game states, e.g. to present different visual overlays for the paused or "game over" states.
    ///
    /// Call `super` to add default logging.
    public func gameControllerDidEnterState(_ state: GKState, from previousState: GKState?) {
        OctopusKit.logForStates.add("\(String(optional: previousState)) → \(String(optional: state))")
    }
    
    /// Called by `OctopusGameState`. To be overriden by a subclass if this same scene is used for different game states, e.g. to remove visual overlays that were presented during a paused or "game over" state.
    ///
    /// Call `super` to add default logging.
    public func gameControllerWillExitState(_ exitingState: GKState, to nextState: GKState) {
        OctopusKit.logForStates.add("\(exitingState) → \(nextState)")
    }
    
    /// Abstract; override in subclass to customize SpriteKit scene transitions.
    public func transition(for nextStateClass: GKState.Type) -> SKTransition? {
        return nil
    }
    
    // MARK: - Entities & Components
    
    /// Adds an entity to the `entities` set, disallowing duplicate entities, and registers its components with the relevant systems.
    ///
    /// If the entity is an `OctopusEntity`, this scene is set as its delegate.
    public func addEntity(_ entity: GKEntity) {
        
        guard entities.insert(entity).inserted else {
            OctopusKit.logForWarnings.add("\(entity) is already in \(self) — Not re-adding")
            return
        }
        
        OctopusKit.logForComponents.add("\(entity.debugDescription), entities.count = \(entities.count)")
        
        // If it's an `OctopusEntity` (as opposed to a basic `GKEntity`) set this scene as its delegate.
        
        if let octopusEntity = entity as? OctopusEntity {
            octopusEntity.delegate = self
        }
        
        // If the entity has as `SpriteKitComponent` or `GKSKNodeComponent` whose node does not belong to any parent, add that node to this scene.
        
        // ℹ️ This lets `OctopusEntityDelegate` methods spawn new visual entities without explicitly specifying the scene, and also lets us conveniently add new entities by simply writing `self.addEntity(OctopusEntity(components: [SpriteKitComponent(node: someSprite)]))`
        
        addChildFromOrphanSpriteKitComponent(in: entity)
        
        // In case the entity added components to itself before its `OctopusEntityDelegate` was set (which ensures that new components are automatically registered with the scene's component systems), add the entity's components to this scene's systems now to make sure we don't miss any.
        
        self.componentSystems.addComponents(foundIn: entity)
        
        // CHECK: Should we issue a warning if the entity has any components that must be updated every frame to perform their function, but this scene does not have any component systems for them? Or would it hurt performance to do such checks every time an entity is added?
        
    }
    
    /// Adds multiple entities to the `entities` set in the order they are listed in the specified array, disallowing duplicate entities, and registers their components with the relevant systems.
    ///
    /// If an entity is an `OctopusEntity`, this scene is set as its delegate.
    public func addEntities(_ entities: [GKEntity]) {
        for entity in entities {
            self.addEntity(entity)
        }
    }
    
    /// Searches the scene for a child node matching the specified name, and creates a new entity associated with it, adding any specified components, and adds the entity to the scene unless choosing not to.
    ///
    /// If more than one child node shares the same name, the first node discovered is used. The entity's name will be set to the node's name.
    ///
    /// Useful for loading scenes and reference nodes built in the Xcode Scene Editor.
    ///
    /// - NOTE: A `SpriteKitComponent` is automatically added to the entity.
    ///
    /// - NOTE: If the node is already associated with an existing entity, it will be re-associated with the new entity.
    ///
    /// - NOTE: For processing multiple entities that share the same name, use `for node in scene[name]`
    ///
    /// - Parameter name: The name to search for. This may be either the literal name of the node or a customized search string. See [Searching the Node Tree](apple-reference-documentation://hsY9-_wZau) in Apple documentation.
    @discardableResult public func createEntityFromChildNode(
        withName name: String,
        addingComponents components: [GKComponent]? = nil,
        addEntityToScene: Bool = true)
        -> OctopusEntity?
    {
        // ℹ️ There is no multiple entity version of this method, as the `components` parameter would cause the SAME components to be added to each entity (because they're reference types), leaving them in effect on only the last entity to be created!
        
        guard let node = self.childNode(withName: name) else {
            OctopusKit.logForWarnings.add("No node with name \"\(name)\" in \(self)")
            return nil
        }
        
        let newEntity = OctopusEntity(name: node.name, node: node) // ⚠️ Set the name to the node's name instead of the search string. :)
        
        if let components = components {
            newEntity.addComponents(components)
        }
        
        if addEntityToScene {
            self.addEntity(newEntity)
        }
        
        return newEntity
    }
    
    /// Attempts to add all of the components from all entities in the scene, to all of the systems in the specified array that match the types of the components.
    ///
    /// If no `systemsCollection` is specified, then `componentSystems` is used.
    public func addAllComponentsFromAllEntities(to systemsCollection: [OctopusComponentSystem]? = nil) {
        
        let systemsCollection = systemsCollection ?? self.componentSystems
        
        OctopusKit.logForFramework.add("systemsCollection = \(systemsCollection)")
        
        for entity in entities {
            systemsCollection.addComponents(foundIn: entity)
        }
    }
    
    /// Adds an `entity`'s `SpriteKitComponent` or `GKSKNodeComponent` node to the scene if that node does not currently have a parent.
    ///
    /// This is useful in cases like spawning sub-entities from a master/parent entity without explicitly specifying the scene.
    public func addChildFromOrphanSpriteKitComponent(in entity: GKEntity) {
        guard
            let node = entity.node, // Either `SpriteKitComponent` or `GKSKNodeComponent` (in case the Scene Editor was used)
            node != self, // Tricky pitfall to avoid there! "A Node can't parent itself" :P
            node.parent == nil
            else { return }
        
        // TODO: Validate 'physicsBody'
        // ⚠️ Before adding the node, handle cases like the node's 'physicsBody' already belong to some other child of this scene, etc. Apparently this does not seem very easy to achieve in SpriteKit and Swift as of 2018-03.
        
        if
            let physicsBody = node.physicsBody,
            physicsBody.node != nil && physicsBody.node! != node
        {
            // ⚠️ NOTE: Apparently this will never occur as SpriteKit replaces `physicsBody.node` when the `physicsBody` is added to a new node.
            OctopusKit.logForErrors.add("\(node) has a \(physicsBody) that belongs to another node! — \(physicsBody.node!)")
            return
        }
        
        OctopusKit.logForDebug.add("\(self) ← \(node)")
        self.addChild(node)    
    }
    
    /// Returns an array of `OctopusEntity`s containing all the entities matching `name`, or `nil` if none were found.
    public func entities(withName name: String) -> [OctopusEntity]? {
        
        let filteredSet = entities.filter {
            
            if let entity = $0 as? OctopusEntity {
                return entity.name == name
            }
            else {
                return false
            }
        }
        
        if
            let filteredArray = Array(filteredSet) as? [OctopusEntity],
            !filteredArray.isEmpty
        {
            return filteredArray
        }
        else {
            return nil
        }
    }
    
    /// Sets the names of all unnamed entities to the name of their `SpriteKitComponent` or `GKSKNodeComponent` nodes.
    public func renameUnnamedEntitiesToNodeNames() {
        for case let entity as (OctopusEntity & Nameable) in entities {
            if
                let node = entity.node,
                entity.name == nil
            {
                entity.name = node.name
            }
        }
    }
    
    /// Marks an entity for removal in the next frame, at the beginning of the next call to `update(_:)`.
    ///
    /// - Returns: `true` if the entry was in the `entities` set.
    ///
    /// This ensures that the list of entities is not mutated during a frame update, which would cause an exception/crash because of mutating a collection while it is being enumerated during the update
    @discardableResult public func removeEntityOnNextUpdate(_ entityToRemove: GKEntity) -> Bool {
        
        guard entities.contains(entityToRemove) else {
            // CHECK: Warn on missing entry if the entity is going to leave anyway?
            // OctopusKit.logForWarnings.add("\(entity) is not registered with \(self)")
            return false
        }
        
        OctopusKit.logForComponents.add("\(entityToRemove.debugDescription)")
        
        // ℹ️ `entitiesToRemoveOnNextUpdate` is a `Set` which prevents duplicate values.
        
        entitiesToRemoveOnNextUpdate.insert(entityToRemove)
        return true
    }
    
    /// Removes an entity from the scene, and unregisters its components from the default component systems array.
    ///
    /// - Returns: `true` if the entry was in the `entities` set and removed.
    ///
    /// - Important: Attempting to modify the list of entities during a frame update will cause an exception/crash, because of mutating a collection while it is being enumerated. To ensure safe removal, use `removeEntityOnNextUpdate(_:)`.
    @discardableResult public func removeEntity(_ entityToRemove: GKEntity) -> Bool {
        
        guard entities.contains(entityToRemove) else {
            // CHECK: Warn on missing entry if the entity is going to leave anyway?
            // OctopusKit.logForWarnings.add("\(entity) is not registered with \(self)")
            return false
        }
        
        // Unregister the entity's components from systems first.
        componentSystems.removeComponents(foundIn: entityToRemove)
        
        // Remove all components from the entity so they can properly dispose of their behavior, e.g. removing a SpriteKit node from the scene.
        entityToRemove.removeAllComponents()
        
        // Clear the entity's delegate.
        // CHECK: Should this step be skipped if this scene is not the delegate?
        (entityToRemove as? OctopusEntity)?.delegate = nil
        
        // NOTE: Remove the entity after components have been removed, to avoid the "entity is not registered with scene" warnings and reduce the potential for other unexpected behavior.
        
        if entities.remove(entityToRemove) != nil {
            OctopusKit.logForComponents.add("Removed \(entityToRemove.debugDescription), entities.count = \(entities.count)")
            return true
        }
        else {
            return false
        }
        
    }
    
    // MARK: OctopusEntityDelegate
    
    /// Registers the new component with the scene's component systems, and if the component was a `SpriteKitComponent` or `GKSKNodeComponent`, adds the node to the scene if the node does not already have a parent.
    /// This assists in cases such as dynamically adding a `SpriteKitComponent` or `GKSKNodeComponent` without knowing which scene or parent to add the node to.
    public func entity(_ entity: GKEntity, didAddComponent component: GKComponent) {
        guard entities.contains(entity) else {
            OctopusKit.logForWarnings.add("\(entity) is not registered with \(self)")
            return
        }
        
        /// Register the component into our systems.
        
        for componentSystem in self.componentSystems {
            if componentSystem.componentClass == type(of: component) {
                componentSystem.addComponent(component)
            }
        }
        
        // If the component was a `SpriteKitComponent` or `GKSKNodeComponent` with an orphan node, adopt that node into this scene.
        
        if component is SpriteKitComponent || component is GKSKNodeComponent {
            addChildFromOrphanSpriteKitComponent(in: entity)
        }
        
    }
    
    public func entity(_ entity: GKEntity, willRemoveComponent component: GKComponent) {
        guard entities.contains(entity) else {
            OctopusKit.logForWarnings.add("\(entity) is not registered with \(self)")
            return
        }
        
        for componentSystem in self.componentSystems {
            if componentSystem.componentClass == type(of: component) {
                componentSystem.removeComponent(component)
            }
        }
    }
    
    /// If the entity that sends this event is in the scene's `entities` array, add the newly-spawned entity to the array, and register its components to the default list of systems.
    /// - Returns: `true` if the entity was accepted and added to the scene. `false` if the entity was rejected or otherwise could not be added to the scene.
    @discardableResult public func entity(_ entity: GKEntity, didSpawn spawnedEntity: GKEntity) -> Bool {
        guard entities.contains(entity) else {
            OctopusKit.logForWarnings.add("\(entity) is not registered with \(self)")
            return false
        }
        
        addEntity(spawnedEntity)
        // componentSystems.addComponents(foundIn: spawnedEntity) // NOTE: Not needed here because it should be done in addEntity(_:), for example in case addEntity(_:) cannot or chooses not to add the entity.
        return true
    }
    
    public func entityDidRequestRemoval(_ entity: GKEntity) {
        // OctopusKit.logForComponents.add("\(entity)") // Already logging in `removeEntityOnNextUpdate(_:)`
        removeEntityOnNextUpdate(entity)
    }
    
    // MARK: - Frame Update
    
    /// Performs any scene-specific updates that need to occur before scene actions are evaluated. This method is the point for updating components, preferably via component systems.
    ///
    /// Also performs timer calculations and handles pausing/unpausing logic, entry removal and other preparations that are necessary for every frame.
    ///
    /// - Note: Does not automatically update components or states. The subclass implementation must call `updateSystems(in: componentSystems, deltaTime: updateTimeDelta)` and `OctopusKit.shared?.gameController.update(deltaTime: updateTimeDelta)` as applicable, or provide custom frame-update logic.
    ///
    /// The preferred pattern in OctopusKit is to simply add entities and components to the scene in a method like `prepareContents()` or `gameControllerDidEnterState(_:from:)`, and use this method to just update all component systems, letting all the per-frame game logic be handled by the `update(_:)` method of each individual component and state class.
    ///
    /// - Important: `super.update(currentTime)` *must* be called for correct functionality (before any other code in most cases), and the `isPaused`, `isPausedBySystem`, `isPausedByPlayer` and `isPausedBySubscene` flags must be handled by the overiding implementation.
    public override func update(_ currentTime: TimeInterval) {
        
        // MARK: Reset Single-Frame Flags
        
        didPresentSubsceneThisFrame = false
        didDismissSubsceneThisFrame = false
        
        // MARK: Entity Removal
        
        // First of all, if any entities were marked for removal since the last update, remove them now.
        // This delayed removal is done to avoid mutating the entities collection while it is being enumerated within the same frame update.
        
        for entityToRemove in entitiesToRemoveOnNextUpdate {
            removeEntity(entityToRemove)
        }
        
        entitiesToRemoveOnNextUpdate.removeAll()
        
        // MARK: Timekeeping
        // Track the time and handle pausing/unpausing so that components and states may be correctly updated.
        
        // THANKS: http://stackoverflow.com/questions/24728881/calculating-delta-in-spritekit-using-swift
        
        // If the scene has been paused by the system, player or UI, just record the time and exit the method.
        
        // ℹ️ Keeping track of the `pausedAtTime` lets us implement "soft" pauses, where the scene may still recieve calls to the `update(_:) method, in order to update visuals, audio and the user interface (e.g. via SpriteKit actions) but the game's logic remains paused.
        
        // ℹ️ The exact consequences of each of the `isPaused...` flags are specific to each game. Some games may choose to prevent the `update(_:)` method from being called at all during a paused state. Other games may simply stop the movement of game characters while continuing to update other elements.
        
        // NOTE: The subclass's implementation must also handle the `isPaused...` flags.
        
        guard !isPaused || !isPausedBySystem || !isPausedByPlayer || !isPausedBySubscene else {
            
            if pausedAtTime == nil {
                pausedAtTime = currentTime
                
                OctopusKit.logForFramework.add("pausedAtTime = \(pausedAtTime!), isPaused = \(isPaused), ispausedBySystem = \(isPausedBySystem), isPausedByPlayer = \(isPausedByPlayer), isPausedBySubscene = \(isPausedBySubscene)")
            }
            return
        }
        
        // If this is not our first frame, calculate the time elapsed (`updateTimeDelta`) between the current frame and the previous frame.
        
        if let lastUpdateTime = self.lastUpdateTime {
            
            // ℹ️ Cannot use the overflow `&+` operator with `Double`, if you're thinking of allowing overflows for `secondsElapsedSinceMovedToView` to increase performance a little.
            
            self.secondsElapsedSinceMovedToView += (currentTime - lastUpdateTime)
            
            // If we were previously paused, disregard the time spent in the paused state.
            
            if let pausedAtTime = self.pausedAtTime {
                
                // Subtract the `lastUpdateTime` from `pausedAtTime` instead of `currentTime`, so that the behavior of components and states appears to continue from the moment when the game was paused.
                
                self.updateTimeDelta = pausedAtTime - lastUpdateTime
                
                // Forget the paused time and clear the instance property as we are no longer paused.
                
                self.pausedAtTime = nil
            }
            else {
                // If we were not paused, calculate the detla value as normal.
                self.updateTimeDelta = currentTime - lastUpdateTime
            }
            
        }
        else {
            // If this is our very first frame, simply zero the delta value.
            self.updateTimeDelta = 0
        }
        
        // Record the current time for the next frame.
        
        self.lastUpdateTime = currentTime
        
        // If more than `updateTimeDeltaMaximum` has passed, clamp `updateTimeDelta` to the maximum desirable value; otherwise use `deltaTime`.
        
        // NOTE: Sometimes the delta may spike. This occurs at the beginning of the game (for the first few frames as things are still being loaded into memory) and occasionally when something else happens on the device (like when a system notification comes in). By capping the delta value we reduce the chance of getting a time step that is too large, preventing elements from "jumping" around erratically.
        
        // THANKS: http://www.raywenderlich.com/62049/sprite-kit-tutorial-make-platform-game-like-super-mario-brothers-part-1
        // THANKS: Apple DemoBots sample
        
        updateTimeDelta = updateTimeDelta > OctopusScene.updateTimeDeltaMaximum ? OctopusScene.updateTimeDeltaMaximum : updateTimeDelta
        
        // MARK: Subscene
        
        // Update the most-recently-added subscene.
        
        if let subscene = self.subscenes.last {
            subscene.update(deltaTime: updateTimeDelta)
        }
        
    }
    
    /// Updates each of the component systems in the order they're listed in the specified array. If no `systemsCollection` is specified, then the scene's `componentSystems` property is used.
    ///
    /// A deterministic order of systems in the component systems array ensures that all components get updated after the other components they depend on.
    public func updateSystems(in systemsCollection: [OctopusComponentSystem]? = nil, deltaTime seconds: TimeInterval) {
        
        let systemsCollection = systemsCollection ?? self.componentSystems
        
        for componentSystem in systemsCollection {
            componentSystem.update(deltaTime: seconds)
        }
    }
    
    /// Increments the frame counter at the end of the current frame update.
    ///
    /// - IMPORTANT: A subclass that overrides this method must call `super.didFinishUpdate()` at the end of its implementation to properly increment the frame counter.
    public override func didFinishUpdate() {
        // Increment the frame count for use in logging and debugging.
        
        // ℹ️ CHECK: PERFORMANCE: Although it makes more sense for `currentFrameNumber` to be incremended in `didFinishUpdate()` (which also eliminates the confusion from seemingly processing input events with a 1-frame lag, according to the logs, because they're received before `update(_:)` is called), we could increment it in `update(_:)` for more performance by calling one less method.
        
        // ℹ️ PERFORMANCE: Allow overflows for `currentFrameNumber` because a `UInt64` is large enough and it improves performance, and the `currentFrameNumber` should mostly be used for logging anyway so it doesn't matter much if it wraps around.
        
        currentFrameNumber = currentFrameNumber &+ 1
    }
    
    // MARK: - Player Input (iOS)
    
    #if os(iOS) // CHECK: Include tvOS?
    
    /// Relays touch-input events to the scene's `TouchEventComponent`.
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {

        #if LOGINPUT
        debugLog()
        #endif
        
        if let inputComponent = self.entity?.componentOrRelay(ofType: TouchEventComponent.self) {
            inputComponent.touchesBegan = TouchEventComponent.TouchEvent(touches: touches, event: event, node: self)
        }
    }
    
    /// Relays touch-input events to the scene's `TouchEventComponent`.
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        
        #if LOGINPUT
        debugLog()
        #endif
        
        if let inputComponent = self.entity?.componentOrRelay(ofType: TouchEventComponent.self) {
            inputComponent.touchesMoved = TouchEventComponent.TouchEvent(touches: touches, event: event, node: self)
        }
    }
    
    /// Relays touch-input events to the scene's `TouchEventComponent`.
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        
        #if LOGINPUT
        debugLog()
        #endif
        
        if let inputComponent = self.entity?.componentOrRelay(ofType: TouchEventComponent.self) {
            inputComponent.touchesCancelled = TouchEventComponent.TouchEvent(touches: touches, event: event, node: self)
        }
    }
    
    /// Relays touch-input events to the scene's `TouchEventComponent`.
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        
        #if LOGINPUT
        debugLog()
        #endif
        
        if let inputComponent = self.entity?.componentOrRelay(ofType: TouchEventComponent.self) {
            inputComponent.touchesEnded = TouchEventComponent.TouchEvent(touches: touches, event: event, node: self)
        }
    }
    
    /// Relays touch-input events to the scene's `TouchEventComponent`.
    public override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        
        #if LOGINPUT
        debugLog()
        #endif
        
        if let inputComponent = self.entity?.componentOrRelay(ofType: TouchEventComponent.self) {
            inputComponent.touchesEstimatedPropertiesUpdated = TouchEventComponent.TouchEvent(touches: touches, event: nil, node: self)
        }
    }
    
    #endif
    
    // MARK: - Physics
    
    /// Relay physics contact events to the scene's `PhysicsContactEventComponent`.
    public func didBegin(_ contact: SKPhysicsContact) {
        
        if let physicsEventComponent = self.entity?.componentOrRelay(ofType: PhysicsContactEventComponent.self) {
            physicsEventComponent.contactBeginnings.append(PhysicsContactEventComponent.ContactEvent(contact: contact, scene: self))
        }
    }
    
    /// Relay physics contact events to the scene's `PhysicsContactEventComponent`.
    public func didEnd(_ contact: SKPhysicsContact) {
        
        if let physicsEventComponent = self.entity?.componentOrRelay(ofType: PhysicsContactEventComponent.self) {
            physicsEventComponent.contactEndings.append(PhysicsContactEventComponent.ContactEvent(contact: contact, scene: self))
        }
    }
    
    // MARK: - Pause/Unpause
    
    /// Called by `OctopusAppDelegate.applicationWillEnterForeground(_:)`. Subclass to implement custom behavior such as going into a player-paused visual state.
    ///
    /// - Important: The overriding implementation must call `super.applicationWillEnterForeground()`.
    public func applicationWillEnterForeground() {
        OctopusKit.logForFramework.add()
        
        if isPausedBySystem {
            // CHECK: Should `OctopusScene.applicationDidBecomeActive()` be called from here too, or should we let `OctopusAppDelegate.applicationDidBecomeActive(_:)` call it?
            applicationDidBecomeActive()
        }

        // TODO: audioEngine.startAndReturnError()
    }
    
    /// Called by `OctopusAppDelegate.applicationDidBecomeActive()` after the player has switched back into the app or interruptions such as a phone call or Control Center have ended.
    ///
    /// - Important: The overriding implementation must call `super.applicationDidBecomeActive()`.
    public func applicationDidBecomeActive() {
        // NOTE: This method gets superfluously called twice after `OctopusAppDelegate.applicationWillEnterForeground(_:)` because of `OctopusScene.applicationWillEnterForeground()` and `OctopusAppDelegate.applicationDidBecomeActive(_:)`.
        
        OctopusKit.logForFramework.add("isPausedBySystem = \(isPausedBySystem)\(isPausedBySystem ? " → false" : "")")
        
        if isPausedBySystem {
            isPaused = false
            isPausedBySystem = false
            physicsWorld.speed = 1
            
            // TODO: audioEngine.unduckMusicVolume()
            
            didUnpauseBySystem() // Allow the subclass to customize the pause/unpause behavior.
        }
    }
    
    /// Called by `OctopusAppDelegate.applicationWillResignActive(_:)` when the player switches out of the app, or on interruptions such as a phone call, Control Center, Notification Center, or other system alerts.
    public func applicationWillResignActive() {
        OctopusKit.logForFramework.add("isPausedBySystem = \(isPausedBySystem)\(isPausedBySystem ? "" : " → true")")
        
        pausedAtTime = lastUpdateTime // CHECK: Should we rely on the stored value instead of getting current time? Probably yes.
        isPausedBySystem = true
        isPaused = true
        physicsWorld.speed = 0
        
        // TODO: audioEngine.duckMusicVolume()
        
        didPauseBySystem() // Allow the subclass to customize the pause/unpause behavior.
    }
    
    /// Called by `OctopusAppDelegate.applicationDidEnterBackground(_:)`
    public func applicationDidEnterBackground() {
        OctopusKit.logForFramework.add()
        
        if !isPausedBySystem {
            applicationWillResignActive()
        }
        pausedAtTime = lastUpdateTime // CHECK: Should we rely on stored value instead of getting current time? Probably yes
        audioEngine.pause() // CHECK: Should the audio engine be paused here?
    }
    
    /// An abstract method for a subclass to customize scene behavior when the game is paused by an system event.
    ///
    /// Called from `OctopusScene.applicationWillResignActive()`.
    ///
    /// - NOTE: If the `OctopusGameController` includes paused/unpaused game states, an `OctopusScene` subclass should manually signal the game controller to transition between those states here.
    public func didPauseBySystem() {}
    
    /// An abstract method for a subclass to customize scene behavior when the game is unpaused by an system event.
    ///
    /// Called from `OctopusScene.applicationDidBecomeActive()`.
    ///
    /// - NOTE: If the `OctopusGameController` includes paused/unpaused game states, an `OctopusScene` subclass should manually signal the game controller to transition between those states here.
    public func didUnpauseBySystem() {}
    
    /// To be called when the player manually chooses to pause or unpause.
    ///
    /// When paused by the player, the gameplay and other game-specific logic is put on hold without preventing the scene from processing frame updates so the visual effects for a paused state can be shown and animated etc.
    public func togglePauseByPlayer() {
        OctopusKit.logForFramework.add("isPausedByPlayer = \(isPausedByPlayer) → \(!isPausedByPlayer)")
        
        isPausedByPlayer = !isPausedByPlayer
        
        if isPausedByPlayer {
            pausedAtTime = lastUpdateTime // CHECK: Should we rely on stored value instead of getting current time?
            // self.physicsWorld.speed = 0.0 // Put in subclass implementation if needed.
            // TODO: audioEngine.duckMusicVolume()
            didPauseByPlayer()
        } else {
            // self.physicsWorld.speed = 1.0 // Put in subclass implementation if needed.
            // TODO: audioEngine.unduckMusicVolume()
            didUnpauseByPlayer()
        }
    }
    
    /// An abstract method for a subclass to customize scene behavior when the game is paused by the player.
    ///
    /// - NOTE: If the `OctopusGameController` includes paused/unpaused game states, an `OctopusScene` subclass should manually signal the game controller to transition between those states here.
    public func didPauseByPlayer() {}
    
    /// An abstract method for a subclass to customize scene behavior when the game is unpaused by the player.
    ///
    /// - NOTE: If the `OctopusGameController` includes paused/unpaused game states, an `OctopusScene` subclass should manually signal the game controller to transition between those states here.
    public func didUnpauseByPlayer() {}
    
    /// To be called when a modal user interface, such as an alert or other dialog which demands player attention, begins or finishes.
    ///
    /// When paused by modal UI, the gameplay and other game-specific logic is put on hold until the player completes the interaction, without preventing the scene from processing frame updates so that the user interface can continue to be displayed.
    public func togglePauseBySubscene() {
        OctopusKit.logForFramework.add("isPausedBySubscene = \(isPausedBySubscene) → (!isPausedBySubscene)")
        
        isPausedBySubscene = !isPausedBySubscene
        
        if isPausedBySubscene {
            pausedAtTime = lastUpdateTime // CHECK: Should we rely on stored value instead of getting current time?
            // self.physicsWorld.speed = 0.0 // Put in subclass implementation if needed.
        } else {
            // self.physicsWorld.speed = 1.0 // Put in subclass implementation if needed.
        }
        
    }
    
    // MARK: - Resizing & Scaling
    
    /// Sets the size of the scene to half the size of the specified view, and sets the `scaleMode` to `aspectFit`.
    ///
    /// For "pixel-perfect" pixel art, you may want to decrease the scene's size by an even factor, then render your bitmaps at `1:1` and let the scene double their size.
    public func halveSizeAndFit(in view: SKView) {
        self.size = view.frame.size.halved
        self.scaleMode = .aspectFit
    }
    
    /// Modifies the scene's scale to match the scene's height to the height of the specified view, cropping the left and right edges of the scene if necessary.
    public func cropAndScaleToFitLandscape(in view: SKView) {
        // CREDIT: Apple Dispenser sample, for landscape-fitted scaling.
        
        let scaleFactor = self.size.height / view.bounds.height // Resize the scene to better use the device aspect ratio.
        self.size.width = view.bounds.width * scaleFactor // If this app runs only in landscape, height always determines scale.
        self.scaleMode = .aspectFit // Set the scale mode to scale to fit the window
    }
    
    /// Modifies the scene's scale to match the scene's width to the width of the specified view, cropping the top and bottom edges of the scene if necessary.
    public func cropAndScaleToFitPortrait(in view: SKView) {
        // CREDIT: Apple Dispenser sample, modified for portrait-fitted scaling.
        
        let scaleFactor = self.size.width / view.bounds.width // Resize the scene to better use the device aspect ratio.
        self.size.height = view.bounds.height * scaleFactor // If this app runs only in portrait, width always determines scale.
        self.scaleMode = .aspectFit // Set the scale mode to scale to fit the window
    }
    
    // MARK: - Subscenes
    
    /// Presents a subscene and pauses the gameplay.
    public func presentSubscene(
        _ subscene: OctopusSubscene,
        onNode parent: SKNode? = nil,
        zPosition: CGFloat? = nil)
    {
        // CHECK: Should there be a limit on the maximum number of subscenes?
        
        // Check if the specified subscene is already being presented.
        
        guard !self.subscenes.contains(subscene) else {
            OctopusKit.logForWarnings.add("\(subscene) already in \(self.subscenes)")
            return
        }
        
        // If no parent node was specified, try adding the subscene to the camera if one is present, otherwise just add it as a direct child of this scene.
        
        let parent = parent ?? self.camera ?? self
        
        OctopusKit.logForFramework.add("\(subscene) on \(parent) at zPosition \(String(optional: zPosition))")
        
        // Set the subscene's properties.
        
        if let zPosition = zPosition {
            subscene.zPosition = zPosition
        }
        
        subscene.delegate = self
        
        // Tell the subscene to create its contents for the specified parent.
        // ℹ️ Must be done after setting the delegate so the subscene can notify it.
        
        subscene.createContents(for: parent)
        
        // Add the subscene to the scene and to the array of active subscenes.
        
        parent.addChild(subscene)
        self.subscenes.append(subscene)
        
        // Pause the main gameplay.
        
        if !isPausedBySubscene {
            togglePauseBySubscene()
        }
        
        // Set the subscene presentation flag.
        // CHECK: Should this be set first so that the subscene may use it?
        
        didPresentSubsceneThisFrame = true
        
    }
    
    // MARK: OctopusSubsceneDelegate
    
    /// A point where `OctopusScene` subclasses can prepare for presenting a subscene, such as dimming and pausing gameplay nodes.
    public func subsceneWillAppear(_ subscene: OctopusSubscene, on parentNode: SKNode) {}
    
    /// A point where `OctopusScene` subclasses can react to the disappearance of a subscene, such as resuming gameplay nodes, and handle its result if any.
    ///
    /// - Important: The overriding implementation must call `super.subsceneDidFinish(subscene, withResult: result)` for `OctopusScene` to correctly remove the subscene and unpause the game.
    public func subsceneDidFinish(_ subscene: OctopusSubscene,
                                  withResult result: OctopusSubsceneResultType?)
    {
        OctopusKit.logForFramework.add("\(subscene) result = \(String(optional: result))")
        
        if let index = self.subscenes.index(of: subscene) {
            self.subscenes.remove(at: index) // ⚠️ CHECK: Will this cause a mutating-while-enumerating exception?
        }
        else {
            OctopusKit.logForWarnings.add("\(subscene) not in the subscene list of \(self)")
        }
        
        subscene.removeFromParent()
        
        if self.subscenes.count < 1 && isPausedBySubscene {
            togglePauseBySubscene()
        }
        
        // Set the subscene dismissal flag.
        
        didDismissSubsceneThisFrame = true
    }
    
    // MARK: - Debugging
    
    public func debugListEntitiesAndComponents() {
        debugLog("""
            🐙
            🔲 Scene = \(self)
            🔶 \(entities.count) Entities...
            """)
        
        for entity in entities {
            debugLog("🔹 \(entity)")
            debugLog("\(entity.components.count) components = \(entity.components)")
        }
        
        debugLog("🔶 \(componentSystems.count) Component Systems...")
        
        for componentSystem in componentSystems {
            debugLog("⚙️ \(componentSystem) componentClass = \(componentSystem.componentClass)")
            debugLog("components = \(componentSystem.components)")
        }
    }
    
}
