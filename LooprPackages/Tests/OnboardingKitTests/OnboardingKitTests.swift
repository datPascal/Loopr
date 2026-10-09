import Foundation
import Testing
import DomainKit
import ProfileKit
import AnalyticsKit
import HealthKitBridge
import NotificationKit
import OnboardingKit

struct OnboardingKitTests {
    @Test
    func gateDrivesLaunchingWelcomePairingProfileAndMainShellInOrder() async throws {
        let repository = InMemoryOnboardingRepository()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let controller = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )

        #expect((await controller.snapshot()).stage == .launching)
        _ = try await controller.advance()
        #expect((await controller.snapshot()).stage == .welcomeDisclosures)
        _ = try await controller.advance()
        #expect((await controller.snapshot()).stage == .whoopHandover)
        _ = try await controller.advance()
        #expect((await controller.snapshot()).stage == .prepareBand)
        _ = try await controller.advance()
        #expect((await controller.snapshot()).stage == .pairing)
        _ = try await controller.requestContextualPairing()
        #expect((await controller.snapshot()).stage == .pairing)
        _ = try await controller.advance()
        #expect((await controller.snapshot()).stage == .profileSetup)
        _ = try await controller.completeProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        #expect((await controller.snapshot()).stage == .appleHealth)
        _ = try await controller.skipPermission(.appleHealth)
        #expect((await controller.snapshot()).stage == .notifications)
        _ = try await controller.skipPermission(.notifications)
        #expect((await controller.snapshot()).stage == .sleepGoal)
        _ = try await controller.skipSleepGoal()
        #expect((await controller.snapshot()).stage == .finish)
        _ = try await controller.finish()
        #expect((await controller.snapshot()).stage == .mainShell)
        #expect(try await profile.readProfile()?.displayName == "Ari")
    }

    @Test
    func gatePersistsEveryStageAndResumesAfterControllerRebuild() async throws {
        let repository = InMemoryOnboardingRepository()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())

        let first = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )
        #expect((await first.snapshot()).stage == .launching)
        _ = try await first.advance()
        #expect((await first.snapshot()).stage == .welcomeDisclosures)
        _ = try await first.advance()
        _ = try await first.advance()
        _ = try await first.advance()
        #expect((await first.snapshot()).stage == .pairing)

        let resumed = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )
        #expect((try await resumed.resume()).stage == .pairing)
    }

    @Test
    func interruptedFlowResumesAtEachCompletedStage() async throws {
        for expectedStage in OnboardingStage.allCases {
            let repository = InMemoryOnboardingRepository()
            let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
            let controller = try await OnboardingFlowController(
                repository: repository,
                profileRepository: profile,
                goalsRepository: profile,
                dateProvider: FixedDateProvider()
            )
            try await walk(controller, to: expectedStage)
            #expect((await controller.snapshot()).stage == expectedStage)
            let relaunched = try await OnboardingFlowController(
                repository: repository,
                profileRepository: profile,
                goalsRepository: profile,
                dateProvider: FixedDateProvider()
            )
            #expect((try await relaunched.resume()).stage == expectedStage)
        }
    }

    @Test
    func pairingPermissionIsRequestedOnlyFromPairingStage() async throws {
        let pairing = RecordingPairingCoordinator()
        let controller = try await makeController(pairing: pairing)

        await #expect(throws: OnboardingTransitionError.self) {
            try await controller.requestContextualPairing()
        }
        #expect(await pairing.requestCount == 0)

        _ = try await controller.advance()
        _ = try await controller.advance()
        _ = try await controller.advance()
        await #expect(throws: OnboardingTransitionError.pairingMustBeContextual) {
            try await controller.requestContextualPairing()
        }
        _ = try await controller.advance()
        _ = try await controller.requestContextualPairing()
        #expect(await pairing.requestCount == 1)
        #expect((await controller.snapshot()).pairingRequested)
    }

    @Test
    func pairingCanBeDeferredWithoutRequestingIt() async throws {
        let pairing = RecordingPairingCoordinator()
        let controller = try await makeController(pairing: pairing)

        // advance() refuses to leave pairing unpaired, so the skip must be its
        // own call. Without it nobody without a band in range can finish setup.
        try await walk(controller, to: .pairing)
        #expect((await controller.snapshot()).stage == .pairing)
        await #expect(throws: OnboardingTransitionError.pairingRequired) {
            try await controller.advance()
        }

        let deferred = try await controller.deferPairing()
        #expect(deferred.stage == .profileSetup)
        #expect(deferred.pairingRequested == false)
        #expect(await pairing.requestCount == 0)
    }

    @Test
    func pairingCannotBeDeferredFromAnotherStage() async throws {
        let controller = try await makeController()
        await #expect(throws: OnboardingTransitionError.self) {
            try await controller.deferPairing()
        }
        #expect((await controller.snapshot()).stage == .launching)
    }

    @Test
    func betaConsentFromEarlierBuildsStillDecodes() throws {
        // Earlier builds offered a WHOOP 5.0 / MG beta switch that did
        // nothing. Its recorded answer must not break a relaunch.
        let legacy = """
        {"stage":"pairing","betaConsent":{"status":"granted","version":"gen5-mg-beta-2026-01","grantedAt":0},"pairingRequested":false,"lastUpdatedAt":0}
        """
        let decoded = try JSONDecoder().decode(OnboardingSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.stage == .pairing)
        #expect(decoded.betaConsent.status == .granted)
        #expect(decoded.betaConsent.version == "gen5-mg-beta-2026-01")
        #expect(!decoded.betaConsent.isGranted)
        let reencoded = try JSONDecoder().decode(OnboardingSnapshot.self, from: JSONEncoder().encode(decoded))
        #expect(reencoded == decoded)
    }

    @Test
    func experimentalSupportConsentIsVersionedAndWithdrawable() async throws {
        let suite = "loopr.experimental-consent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsBetaConsentStore(defaults: defaults)
        #expect(!store.load().isGranted)
        let granted = try store.setEnabled(true, at: Date(timeIntervalSince1970: 10))
        #expect(granted.isGranted)
        #expect(granted.version == BetaConsent.currentVersion)
        let withdrawn = try store.setEnabled(false, at: Date(timeIntervalSince1970: 20))
        #expect(!withdrawn.isGranted)
        #expect(withdrawn.withdrawnAt == Date(timeIntervalSince1970: 20))

        let repository = InMemoryOnboardingRepository(snapshot: OnboardingSnapshot(
            stage: .pairing, lastUpdatedAt: Date(timeIntervalSince1970: 0)
        ))
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let flow = try await OnboardingFlowController(repository: repository, profileRepository: profile, dateProvider: FixedDateProvider())
        let enabled = try await flow.setExperimentalSupport(true)
        #expect(enabled.betaConsent.isGranted)
        let disabled = try await flow.setExperimentalSupport(false)
        #expect(!disabled.betaConsent.isGranted)
        #expect((try await repository.load())?.betaConsent.status == .withdrawn)
    }

    @Test
    func migrationChoiceIsDurableAndLeavesConsentAlone() async throws {
        let repository = InMemoryOnboardingRepository()
        let controller = try await OnboardingFlowController(
            repository: repository,
            profileRepository: InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider()),
            dateProvider: FixedDateProvider()
        )
        _ = try await controller.chooseMigration(.startFresh)
        #expect((await controller.snapshot()).migrationChoice == .startFresh)
        let resumed = try await OnboardingFlowController(
            repository: repository,
            profileRepository: InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider()),
            dateProvider: FixedDateProvider()
        )
        #expect((try await resumed.resume()).migrationChoice == .startFresh)
        #expect((try await resumed.resume()).betaConsent.status == .neverGranted)
    }

    @Test
    func profileCompletionPreservesAbsentOptionalFields() async throws {
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )
        try await walk(controller, to: .profileSetup)
        _ = try await controller.completeProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))

        let saved = try await profile.readProfile()
        #expect((await controller.snapshot()).stage == .appleHealth)
        #expect(saved?.birthYear == nil)
        #expect(saved?.heightCentimeters == nil)
        #expect(saved?.weightKilograms == nil)
        #expect(saved?.timezoneIdentifier == nil)
    }

    @Test
    func destructiveActionsAreSeparateAndNarrow() async throws {
        let effects = InMemoryOnboardingDataEffects()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        _ = try await profile.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            dataEffects: effects,
            dateProvider: FixedDateProvider()
        )

        try await controller.perform(.resetProfile)
        #expect(await effects.actions == [.resetProfile])
        #expect(await effects.bandPaired)
        #expect(await effects.appDataExists)
        #expect(try await profile.readProfile() == nil)

        try await controller.perform(.forgetBand)
        #expect(await effects.actions == [.resetProfile, .forgetBand])
        #expect(!(await effects.bandPaired))
        #expect(await effects.appDataExists)

        try await controller.perform(.deleteAllData)
        #expect(await effects.actions == [.resetProfile, .forgetBand, .deleteAllData])
        #expect(!(await effects.appDataExists))
    }

    @Test
    func resetProfileActionDoesNotForgetBandOrDeleteAppData() async throws {
        let effects = InMemoryOnboardingDataEffects()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        _ = try await profile.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            dataEffects: effects,
            dateProvider: FixedDateProvider()
        )
        try await controller.perform(.resetProfile)
        #expect(await effects.actions == [.resetProfile])
        #expect(await effects.bandPaired)
        #expect(await effects.appDataExists)
        #expect(try await profile.readProfile() == nil)
    }

    @Test
    func forgetBandActionDoesNotResetProfileOrDeleteAppData() async throws {
        let effects = InMemoryOnboardingDataEffects()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        _ = try await profile.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            dataEffects: effects,
            dateProvider: FixedDateProvider()
        )
        try await controller.perform(.forgetBand)
        #expect(await effects.actions == [.forgetBand])
        #expect(!(await effects.bandPaired))
        #expect(await effects.appDataExists)
        #expect(try await profile.readProfile()?.displayName == "Ari")
    }

    @Test
    func deleteAllDataActionClearsProfileBandAndAppDataOnly() async throws {
        let effects = InMemoryOnboardingDataEffects()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        _ = try await profile.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            dataEffects: effects,
            dateProvider: FixedDateProvider()
        )
        try await controller.perform(.deleteAllData)
        #expect(await effects.actions == [.deleteAllData])
        #expect(!(await effects.bandPaired))
        #expect(!(await effects.appDataExists))
        #expect(try await profile.readProfile() == nil)
    }

    @Test
    func allUniversalStateFixturesAreDistinctAndNonEmpty() {
        #expect(OnboardingUniversalState.allCases.count == 14)
        #expect(OnboardingStateFixtures.all.count == 14)
        #expect(Set(OnboardingStateFixtures.all.map(\.title)).count == 14)
        let absent = OnboardingStateFixtures.all.first { $0.state == .absentMetric }
        let zero = OnboardingStateFixtures.all.first { $0.state == .measuredZero }
        #expect(absent?.title != zero?.title)
        #expect(absent?.detail != zero?.detail)
    }

    @Test
    func applicableOnboardingStatesHaveRenderableLabelsAndAccessibilityContracts() {
        let applicable: Set<OnboardingUniversalState> = [
            .loading, .disconnected, .bluetoothOff, .permissionDenied, .unsupportedHardware, .recoverableError
        ]
        for state in applicable {
            let rendered = OnboardingStateRenderer.render(state)
            #expect(!rendered.title.isEmpty)
            #expect(!rendered.detail.isEmpty)
            #expect(!rendered.voiceOverLabel.isEmpty)
            #expect(!rendered.accessibilityIdentifier.isEmpty)
        }
        let contract = OnboardingAccessibilityContract()
        #expect(contract.supportsDynamicType)
        #expect(contract.supportsReduceMotion)
        #expect(contract.usesSemanticVoiceOverLabels)
        #expect(OnboardingAccessibilityContract.minimumTouchTarget >= 44)
        #expect(OnboardingTelemetryPolicy.emitsEventsBeforeConsent == false)
        #expect(OnboardingDisclosureCopy.nonAffiliation.contains("independent"))
        #expect(OnboardingDisclosureCopy.healthBoundary.contains("medical"))
        #expect(OnboardingDisclosureCopy.noAccount.contains("not tied to any login"))
        #expect(OnboardingDisclosureCopy.stableGen4.contains("WHOOP 4.0"))
        #expect(OnboardingAccessibilityContract.requiredScreenIdentifiers.contains("onboarding-delete-all-data"))
        #expect(!OnboardingAccessibilityContract.requiredScreenIdentifiers.contains { $0.contains("gen5") })
    }

    // MARK: 2026-09 flow

    @Test
    func stepOrderIsTheVisibleSequenceWithGatesAtEachEnd() {
        #expect(OnboardingStage.visibleSteps == [
            .welcomeDisclosures, .whoopHandover, .prepareBand, .pairing, .profileSetup,
            .appleHealth, .notifications, .sleepGoal, .finish
        ])
        #expect(OnboardingStage.stepCount == 9)
        #expect(OnboardingStage.launching.stepNumber == nil)
        #expect(OnboardingStage.mainShell.stepNumber == nil)
        #expect(OnboardingStage.welcomeDisclosures.stepNumber == 1)
        #expect(OnboardingStage.finish.stepNumber == 9)
        #expect(OnboardingStage.whoopHandover.stepNumber == 2)
        var stage = OnboardingStage.launching
        var walked: [OnboardingStage] = [stage]
        while let next = stage.next { walked.append(next); stage = next }
        #expect(walked == OnboardingStage.allCases)
        for visible in OnboardingStage.visibleSteps.dropFirst() {
            #expect(visible.previous?.next == visible)
        }
        #expect(OnboardingStage.welcomeDisclosures.previous == nil)
    }

    @Test
    func existingStageRawValuesAreUnchanged() {
        // Persisted snapshots from earlier builds must keep decoding.
        #expect(OnboardingStage.launching.rawValue == "launching")
        #expect(OnboardingStage.welcomeDisclosures.rawValue == "welcomeDisclosures")
        #expect(OnboardingStage.prepareBand.rawValue == "prepareBand")
        #expect(OnboardingStage.whoopHandover.rawValue == "whoopHandover")
        #expect(OnboardingStage.pairing.rawValue == "pairing")
        #expect(OnboardingStage.profileSetup.rawValue == "profileSetup")
        #expect(OnboardingStage.mainShell.rawValue == "mainShell")
    }

    @Test
    func snapshotsFromEarlierBuildsDecodeWithoutTheNewFields() throws {
        let legacy = """
        {"stage":"profileSetup","betaConsent":{"status":"neverGranted"},"pairingRequested":true,"lastUpdatedAt":0}
        """
        let decoded = try JSONDecoder().decode(OnboardingSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.stage == .profileSetup)
        #expect(decoded.pairingRequested)
        #expect(decoded.appleHealthOutcome == nil)
        #expect(decoded.notificationsOutcome == nil)
        #expect(decoded.sleepGoalHours == nil)
    }

    @Test
    func backMovesOneStepAndKeepsWhatWasRecorded() async throws {
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let repository = InMemoryOnboardingRepository()
        let controller = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            goalsRepository: profile,
            dateProvider: FixedDateProvider()
        )
        // Back on the first visible step does nothing.
        _ = try await controller.advance()
        #expect(try await controller.goBack().stage == .welcomeDisclosures)

        try await walk(controller, to: .appleHealth)
        let beforeBack = await controller.snapshot()
        #expect(beforeBack.pairingRequested)
        #expect(beforeBack.profileDraft != nil)

        let back = try await controller.goBack()
        #expect(back.stage == .profileSetup)
        #expect(back.pairingRequested)
        #expect(back.profileDraft == beforeBack.profileDraft)
        #expect(try await controller.goBack().stage == .pairing)
        // Already paired, so Continue on the pairing step still works.
        #expect(try await controller.advance().stage == .profileSetup)
        // A saved profile lets the person continue without re-entering it.
        #expect(try await controller.advance().stage == .appleHealth)

        // Back is durable across a relaunch.
        _ = try await controller.goBack()
        let relaunched = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )
        #expect(try await relaunched.resume().stage == .profileSetup)
    }

    @Test
    func finishedOnboardingCannotGoBack() async throws {
        let controller = try await makeController()
        try await walk(controller, to: .mainShell)
        #expect(try await controller.goBack().stage == .mainShell)
    }

    @Test
    func profileStepCannotBeSkippedWithoutAProfile() async throws {
        let controller = try await makeController()
        try await walk(controller, to: .profileSetup)
        await #expect(throws: OnboardingTransitionError.profileRequired) {
            try await controller.advance()
        }
    }

    @Test
    func unnamedProfileCompletesOnboarding() async throws {
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )
        try await walk(controller, to: .profileSetup)
        _ = try await controller.completeProfile(ProfileDraft(birthYear: 1990, unitSystem: .metric))
        #expect((await controller.snapshot()).stage == .appleHealth)
        #expect(try await profile.readProfile()?.displayName == "")
    }

    @Test
    func deferringFromAnyBandStepSkipsToProfileWithoutPairing() async throws {
        #expect(OnboardingStage.bandSteps == [.whoopHandover, .prepareBand, .pairing])
        for stage in [OnboardingStage.whoopHandover, .prepareBand, .pairing] {
            let pairing = RecordingPairingCoordinator()
            let controller = try await makeController(pairing: pairing)
            try await walk(controller, to: stage)
            let deferred = try await controller.deferPairing()
            #expect(deferred.stage == .profileSetup)
            #expect(!deferred.pairingRequested)
            #expect(await pairing.requestCount == 0)
        }
    }

    @Test
    func pairingRequestStaysOnThePairingStep() async throws {
        let controller = try await makeController()
        try await walk(controller, to: .pairing)
        let requested = try await controller.requestContextualPairing()
        #expect(requested.stage == .pairing)
        #expect(requested.pairingRequested)
    }

    @Test
    func failedPairingRequestIsNotRecorded() async throws {
        let controller = try await makeController(pairing: FailingPairingCoordinator())
        try await walk(controller, to: .pairing)
        await #expect(throws: FailingPairingCoordinator.Failure.self) {
            try await controller.requestContextualPairing()
        }
        #expect(!(await controller.snapshot()).pairingRequested)
        await #expect(throws: OnboardingTransitionError.pairingRequired) {
            try await controller.advance()
        }
    }

    @Test
    func permissionsAreRequestedOnlyFromTheirOwnStep() async throws {
        let permissions = RecordingPermissionCoordinator(answer: .granted)
        let controller = try await makeController(permissions: permissions)
        for permission in OnboardingPermission.allCases {
            await #expect(throws: OnboardingTransitionError.permissionMustBeContextual(permission)) {
                try await controller.requestPermission(permission)
            }
        }
        try await walk(controller, to: .appleHealth)
        await #expect(throws: OnboardingTransitionError.permissionMustBeContextual(.notifications)) {
            try await controller.requestPermission(.notifications)
        }
        #expect(await permissions.requests.isEmpty)

        let afterHealth = try await controller.requestPermission(.appleHealth)
        #expect(afterHealth.stage == .notifications)
        #expect(afterHealth.appleHealthOutcome == .granted)
        let afterNotifications = try await controller.requestPermission(.notifications)
        #expect(afterNotifications.stage == .sleepGoal)
        #expect(afterNotifications.notificationsOutcome == .granted)
        #expect(await permissions.requests == [.appleHealth, .notifications])
    }

    @Test
    func deniedPermissionStillMovesOn() async throws {
        let permissions = RecordingPermissionCoordinator(answer: .denied)
        let controller = try await makeController(permissions: permissions)
        try await walk(controller, to: .notifications)
        let next = try await controller.requestPermission(.notifications)
        #expect(next.stage == .sleepGoal)
        #expect(next.notificationsOutcome == .denied)
    }

    @Test
    func skippingAPermissionNeverAsksIOS() async throws {
        let permissions = RecordingPermissionCoordinator(answer: .granted)
        let controller = try await makeController(permissions: permissions)
        try await walk(controller, to: .appleHealth)
        let health = try await controller.skipPermission(.appleHealth)
        #expect(health.stage == .notifications)
        #expect(health.appleHealthOutcome == .skipped)
        let notifications = try await controller.skipPermission(.notifications)
        #expect(notifications.stage == .sleepGoal)
        #expect(notifications.notificationsOutcome == .skipped)
        #expect(await permissions.requests.isEmpty)
        await #expect(throws: OnboardingTransitionError.self) {
            try await controller.skipPermission(.appleHealth)
        }
    }

    @Test
    func sleepGoalIsSavedAsTheCanonicalSleepGoal() async throws {
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            goalsRepository: profile,
            dateProvider: FixedDateProvider()
        )
        try await walk(controller, to: .sleepGoal)
        await #expect(throws: OnboardingTransitionError.invalidSleepGoal) {
            try await controller.saveSleepGoal(hours: 2)
        }
        await #expect(throws: OnboardingTransitionError.invalidSleepGoal) {
            try await controller.saveSleepGoal(hours: .nan)
        }
        let saved = try await controller.saveSleepGoal(hours: 7.5)
        #expect(saved.stage == .finish)
        #expect(saved.sleepGoalHours == 7.5)
        let goals = try await profile.readGoals()
        #expect(goals.count == 1)
        #expect(goals.first?.type == .sleep)
        #expect(goals.first?.target == 7.5)
        #expect(goals.first?.unit == "hours")
    }

    @Test
    func skippingTheSleepGoalWritesNothing() async throws {
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let controller = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: profile,
            goalsRepository: profile,
            dateProvider: FixedDateProvider()
        )
        try await walk(controller, to: .sleepGoal)
        let skipped = try await controller.skipSleepGoal()
        #expect(skipped.stage == .finish)
        #expect(skipped.sleepGoalHours == nil)
        #expect(try await profile.readGoals().isEmpty)
    }

    @Test
    func sleepGoalWithoutAGoalsRepositoryFailsClosed() async throws {
        let controller = try await makeController()
        try await walk(controller, to: .sleepGoal)
        await #expect(throws: OnboardingTransitionError.goalsUnavailable) {
            try await controller.saveSleepGoal(hours: 8)
        }
        #expect((await controller.snapshot()).stage == .sleepGoal)
    }

    @Test
    func finishOnlyFromTheFinishStep() async throws {
        let controller = try await makeController()
        try await walk(controller, to: .sleepGoal)
        await #expect(throws: OnboardingTransitionError.self) {
            try await controller.finish()
        }
        _ = try await controller.skipSleepGoal()
        #expect(try await controller.finish().stage == .mainShell)
    }

    @Test
    func permissionAnswersAndConsentSurviveARelaunch() async throws {
        let repository = InMemoryOnboardingRepository()
        let profile = InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider())
        let controller = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            goalsRepository: profile,
            permissionCoordinator: RecordingPermissionCoordinator(answer: .granted),
            dateProvider: FixedDateProvider()
        )
        try await walk(controller, to: .appleHealth)
        _ = try await controller.requestPermission(.appleHealth)
        _ = try await controller.skipPermission(.notifications)
        _ = try await controller.saveSleepGoal(hours: 8)

        let relaunched = try await OnboardingFlowController(
            repository: repository,
            profileRepository: profile,
            dateProvider: FixedDateProvider()
        )
        let resumed = try await relaunched.resume()
        #expect(resumed.stage == .finish)
        #expect(resumed.appleHealthOutcome == .granted)
        #expect(resumed.notificationsOutcome == .skipped)
        #expect(resumed.sleepGoalHours == 8)
        #expect(resumed.betaConsent.status == .neverGranted)
        #expect(resumed.pairingRequested)
    }

    // MARK: Profile form

    @Test
    func blankProfileFormIsValidAndSavesOnlyUnitsAndTimeZone() throws {
        let form = OnboardingProfileForm()
        #expect(form.canSubmit)
        let draft = form.draft(currentYear: 2026, timeZone: TimeZone(identifier: "Asia/Singapore")!)
        #expect(draft.displayName == nil)
        #expect(draft.birthYear == nil)
        #expect(draft.biologicalSex == nil)
        #expect(draft.heightCentimeters == nil)
        #expect(draft.weightKilograms == nil)
        #expect(draft.timezoneIdentifier == "Asia/Singapore")
        #expect(draft.unitSystem == .metric)
        try ProfileValidator.validate(draft, currentYear: 2026)
    }

    @Test
    func profileFormConvertsMetricEntries() throws {
        var form = OnboardingProfileForm()
        form.name = "  Alex "
        form.age = "34"
        form.sex = .male
        form.heightPrimary = "181"
        form.weight = "76,5"
        let draft = form.draft(currentYear: 2026, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        #expect(draft.displayName == "Alex")
        #expect(draft.birthYear == 1992)
        #expect(draft.biologicalSex == .male)
        #expect(draft.heightCentimeters == 181)
        #expect(draft.weightKilograms == 76.5)
        #expect(form.estimatedMaxHeartRate == 184)
        try ProfileValidator.validate(draft, currentYear: 2026)
    }

    @Test
    func profileFormConvertsImperialEntries() throws {
        var form = OnboardingProfileForm()
        form.unitSystem = .imperial
        form.heightPrimary = "5"
        form.heightInches = "11"
        form.weight = "165"
        let draft = form.draft(currentYear: 2026)
        #expect(abs((draft.heightCentimeters ?? 0) - 180.34) < 0.001)
        #expect(abs((draft.weightKilograms ?? 0) - 74.843) < 0.01)
        #expect(draft.unitSystem == .imperial)
        #expect(form.canSubmit)
    }

    @Test
    func switchingUnitsConvertsWhatWasTyped() {
        var form = OnboardingProfileForm()
        form.heightPrimary = "180"
        form.weight = "80"
        form.switchUnits(to: .imperial)
        #expect(form.heightPrimary == "5")
        #expect(form.heightInches == "11")
        #expect(form.weight == "176.4")
        form.switchUnits(to: .metric)
        #expect(form.heightPrimary == "180")
        #expect(form.heightInches == "")
        #expect(form.weight == "80")
    }

    @Test
    func profileFormFlagsImplausibleEntriesWithoutGuessing() {
        var form = OnboardingProfileForm()
        form.age = "9"
        form.heightPrimary = "18"
        form.weight = "abc"
        #expect(form.issues == [.age, .height, .weight])
        #expect(!form.canSubmit)
        #expect(form.estimatedMaxHeartRate == nil)
        let draft = form.draft(currentYear: 2026)
        #expect(draft.birthYear == nil)

        form.unitSystem = .imperial
        form.heightPrimary = "5"
        form.heightInches = "14"
        form.age = "40"
        form.weight = ""
        #expect(form.issues == [.height])
        for issue in [OnboardingProfileForm.Issue.age, .height, .weight] {
            #expect(!issue.message.isEmpty)
        }
    }

    @Test
    func derivedMaxHeartRateFollowsTheTypedAge() {
        var form = OnboardingProfileForm()
        #expect(form.estimatedMaxHeartRate == nil)
        form.age = "30"
        #expect(form.estimatedMaxHeartRate == 187)
        form.age = "50"
        #expect(form.estimatedMaxHeartRate == 173)
        form.age = "130"
        #expect(form.estimatedMaxHeartRate == nil)
    }

    @Test
    func profileFormRestoresFromASavedDraft() {
        let draft = ProfileDraft(
            displayName: "Ari",
            birthYear: 1990,
            biologicalSex: .undisclosed,
            heightCentimeters: 180.34,
            weightKilograms: 74.8427,
            timezoneIdentifier: "Europe/Berlin",
            unitSystem: .imperial
        )
        let form = OnboardingProfileForm(draft: draft, currentYear: 2026)
        #expect(form.name == "Ari")
        #expect(form.age == "36")
        #expect(form.sex == .undisclosed)
        #expect(form.heightPrimary == "5")
        #expect(form.heightInches == "11")
        #expect(form.weight == "165")
        #expect(form.unitSystem == .imperial)
    }

    // MARK: Copy

    @Test
    func copyFollowsTheCopyRules() {
        let phases: [OnboardingPairingPhase] = [
            .idle, .confirmReady, .choosing, .connecting, .connected, .bluetoothOff, .cancelled, .notFound, .bondRepair
        ]
        var strings: [String] = [
            OnboardingCopy.Welcome.title, OnboardingCopy.Welcome.promise, OnboardingCopy.Welcome.privateDetail,
            OnboardingCopy.Welcome.independentTitle,
            OnboardingCopy.Handover.title, OnboardingCopy.Handover.detail, OnboardingCopy.Handover.bluetoothTitle,
            OnboardingCopy.Handover.bluetoothDetail, OnboardingCopy.Handover.openSettingsNote,
            OnboardingCopy.Handover.swipeTitle, OnboardingCopy.Handover.swipeDetail,
            OnboardingCopy.Handover.otherDeviceTitle, OnboardingCopy.Handover.otherDeviceDetail,
            OnboardingCopy.Handover.reverseNote,
            OnboardingCopy.Prepare.title, OnboardingCopy.Prepare.detail, OnboardingCopy.Prepare.offDetail,
            OnboardingCopy.Prepare.tapDetail, OnboardingCopy.Prepare.newBandDetail,
            OnboardingCopy.Pairing.timingDetail, OnboardingCopy.Pairing.nearbyDetail,
            OnboardingCopy.Pairing.helpTitle, OnboardingCopy.Pairing.helpIntro,
            OnboardingCopy.Pairing.bondRepairWarning, OnboardingCopy.Pairing.sharedLinkTitle,
            OnboardingCopy.Pairing.sharedLinkDetail, OnboardingCopy.Pairing.stableDetail,
            OnboardingCopy.Profile.detail, OnboardingCopy.Profile.maxHeartRateNote,
            OnboardingCopy.Health.title, OnboardingCopy.Health.detail, OnboardingCopy.Health.writeOnlyDetail,
            OnboardingCopy.Health.choiceNote,
            OnboardingCopy.Notifications.title, OnboardingCopy.Notifications.detail,
            OnboardingCopy.SleepNeedStep.title, OnboardingCopy.SleepNeedStep.detail,
            OnboardingCopy.SleepNeedStep.skipNote(defaultHours: OnboardingFacts.defaultSleepNeedHours),
            OnboardingCopy.Finish.title, OnboardingCopy.Finish.deferredTitle, OnboardingCopy.Finish.wearDetail,
            OnboardingCopy.Finish.baselineTitle(nights: OnboardingFacts.recoveryLearningNights),
            OnboardingCopy.Finish.baselineDetail(nights: OnboardingFacts.recoveryLearningNights),
            OnboardingCopy.Finish.syncDetail, OnboardingCopy.Finish.laterDetail, OnboardingCopy.Finish.refreshDetail,
            OnboardingCopy.Finish.connectingTitle, OnboardingCopy.Finish.connectingDetail,
            OnboardingCopy.Pairing.helpTitle(for: .failed("x")), OnboardingCopy.Pairing.helpTitle(for: .choosing),
            OnboardingCopy.DataControls.detail
        ]
        strings += OnboardingCopy.Pairing.helpItems + OnboardingCopy.Pairing.bondRepairSteps
        strings += phases.flatMap { [OnboardingCopy.Pairing.title(for: $0), OnboardingCopy.Pairing.detail(for: $0)] }
        strings += OnboardingNotificationGroup.allCases.flatMap {
            [OnboardingCopy.Notifications.title(for: $0), OnboardingCopy.Notifications.detail(for: $0)]
        }
        strings += OnboardingStage.allCases.map(OnboardingCopy.Chrome.headerTitle(for:))
        let banned = ["\u{2014}", "\u{2013}", "!", "diagnos", "medical-grade", "clinically", "arrhythm", "AFib",
                      "apnea", "abnormal", "dangerous", "blood pressure", "\u{201C}", "\u{201D}", "\u{2019}"]
        for string in strings {
            #expect(!string.isEmpty)
            for word in banned {
                #expect(!string.localizedCaseInsensitiveContains(word), "\(string) contains \(word)")
            }
        }
    }

    @Test
    func copyNeverClaimsToBeWhoop() {
        // Loopr names WHOOP only as the person's band and app. It never
        // speaks as WHOOP, and the non-affiliation line stays.
        #expect(OnboardingDisclosureCopy.nonAffiliation == "Loopr is independent from WHOOP.")
        #expect(OnboardingCopy.Welcome.independentTitle == "Not made by WHOOP")
        let all = [
            OnboardingCopy.Welcome.promise, OnboardingCopy.Handover.detail, OnboardingCopy.Pairing.stableDetail,
            OnboardingCopy.Pairing.sharedLinkDetail
        ]
        for string in all {
            for claim in ["WHOOP Loopr", "by WHOOP", "official", "WHOOP-approved", "partner"] {
                #expect(!string.localizedCaseInsensitiveContains(claim), "\(string) contains \(claim)")
            }
        }
    }

    @Test
    func handoverAndPairingCopyFollowTheResearch() {
        // Handover research: these three claims in earlier copy were wrong
        // or unverified.
        let everything = [
            OnboardingCopy.Handover.detail, OnboardingCopy.Handover.bluetoothDetail, OnboardingCopy.Handover.swipeDetail,
            OnboardingCopy.Pairing.helpIntro, OnboardingCopy.Prepare.tapDetail, OnboardingCopy.Prepare.newBandDetail
        ] + OnboardingCopy.Pairing.helpItems
        for string in everything {
            #expect(!string.localizedCaseInsensitiveContains("never show up"))
            #expect(!string.localizedCaseInsensitiveContains("one app at a time"))
            #expect(!string.localizedCaseInsensitiveContains("to itself"))
        }
        // Step 1: Bluetooth access off, by its Settings path.
        #expect(OnboardingCopy.Handover.bluetoothDetail.contains("Privacy & Security"))
        #expect(OnboardingCopy.Handover.bluetoothDetail.contains("Bluetooth"))
        #expect(OnboardingCopy.Handover.bluetoothDetail.contains("delete the app"))
        // Step 3: other phones and iPads.
        #expect(OnboardingCopy.Handover.otherDeviceTitle.contains("iPad"))
        // Pairing mode: the tap method first, with its timing, then the
        // battery pack only for a band that was never paired.
        #expect(OnboardingCopy.Prepare.tapDetail.contains("two fingers"))
        #expect(OnboardingCopy.Prepare.tapDetail.contains("sides"))
        #expect(OnboardingCopy.Prepare.detail.contains("15 to 20 seconds"))
        #expect(OnboardingCopy.Prepare.newBandDetail.contains("15 minutes"))
        #expect(OnboardingCopy.Prepare.newBandTitle.contains("never paired"))
        // Connect within about three minutes, band next to the iPhone.
        #expect(OnboardingCopy.Pairing.timingDetail.contains("3 minutes"))
        // Forget This Device only as the fix for a bond error, with its cost.
        #expect(OnboardingCopy.Pairing.bondRepairSteps.contains { $0.contains("Forget This Device") })
        #expect(OnboardingCopy.Pairing.bondRepairWarning.contains("every device on your Apple Account"))
        for string in everything {
            #expect(!string.contains("Forget This Device"))
        }
        // The sheet offers a stable band and, after consent, experimental bands.
        #expect(OnboardingCopy.Pairing.detail(for: .choosing).contains("your band"))
        #expect(OnboardingCopy.Pairing.pickerName == "WHOOP 4.0")
        // The hint is worded as a hint.
        #expect(OnboardingCopy.Pairing.sharedLinkTitle.contains("may"))
        #expect(OnboardingCopy.Pairing.sharedLinkDetail.contains("If that's the WHOOP app"))
    }

    @Test
    func findHelpNeverShowsWhileABandIsConnecting() {
        #expect(!OnboardingPairingPhase.connecting.offersFindHelp)
        #expect(!OnboardingPairingPhase.connected.offersFindHelp)
        #expect(!OnboardingPairingPhase.idle.offersFindHelp)
        #expect(!OnboardingPairingPhase.bondRepair.offersFindHelp)
        #expect(!OnboardingPairingPhase.bluetoothOff.offersFindHelp)
        #expect(OnboardingPairingPhase.choosing.offersFindHelp)
        #expect(OnboardingPairingPhase.choosing.findHelpWaits)
        for phase: OnboardingPairingPhase in [.cancelled, .notFound, .failed("x")] {
            #expect(phase.offersFindHelp)
            #expect(!phase.findHelpWaits)
        }
        #expect(OnboardingPairingPhase.bondRepair.isProblem)
    }

    @Test
    func healthStepListsEveryTypeTheFreshInstallRequestAsksFor() {
        let request = OnboardingHealthRequest.freshInstall
        #expect(request.importsHistory)
        let writes = request.orderedWrites
        let reads = request.orderedReads
        #expect(Set(writes) == Set(ExportMetricKind.allCases.map(OnboardingHealthType.write)))
        #expect(Set(reads) == Set(HealthHistoryQuantity.allCases.map(OnboardingHealthType.read) + [.readSleep]))
        #expect(writes.count == ExportMetricKind.allCases.count)
        #expect(reads.count == HealthHistoryQuantity.allCases.count + 1)
        #expect(Set(writes.map(\.name)).count == writes.count)
        #expect(Set(reads.map(\.name)).count == reads.count)
        #expect(!request.reads.contains(.oxygenSaturation))
        #expect(OnboardingHealthRequest(writes: [], reads: [.oxygenSaturation], readsSleep: false).orderedReads.isEmpty)
        for type in writes + reads {
            #expect(!type.name.isEmpty)
            #expect(!type.symbol.isEmpty)
        }
        #expect(OnboardingCopy.Health.detail(for: request) == OnboardingCopy.Health.detail)
        #expect(OnboardingCopy.Health.detail.contains("reads"))
    }

    @Test
    func healthStepFollowsANarrowerRequest() {
        let request = OnboardingHealthRequest(writes: [.heartRate, .completedWorkout], reads: [], readsSleep: false)
        #expect(!request.importsHistory)
        #expect(request.orderedWrites.map(\.name) == ["Heart rate", "Workouts"])
        #expect(request.orderedReads.isEmpty)
        #expect(OnboardingCopy.Health.detail(for: request) == OnboardingCopy.Health.writeOnlyDetail)
        #expect(!OnboardingCopy.Health.writeOnlyDetail.contains("reads"))

        let sleepOnly = OnboardingHealthRequest(writes: [], reads: [], readsSleep: true)
        #expect(sleepOnly.importsHistory)
        #expect(sleepOnly.orderedReads == [.readSleep])
        #expect(OnboardingCopy.Health.spokenList("Loopr reads", sleepOnly.orderedReads) == "Loopr reads: sleep")
    }

    @Test
    func notificationStepCoversEveryFamilyLooprSends() {
        for family in NotificationFamily.allCases {
            let group = OnboardingNotificationGroup.group(for: family)
            if NotificationFamily.unwired.contains(family) {
                #expect(group == nil, "\(family) sends nothing yet, so the step must not promise it")
            } else if family.isEnabledByDefault {
                #expect(group != nil && group != .offUntilChosen, "\(family) is on by default but not listed")
            } else {
                #expect(group == .offUntilChosen, "\(family) is opt-in and must be listed as off")
            }
        }
        let listed = Set(OnboardingNotificationGroup.allCases.flatMap(\.families))
        let wired = Set(NotificationFamily.allCases).subtracting(NotificationFamily.unwired)
        #expect(listed == wired)
        #expect(OnboardingNotificationGroup.offUntilChosen.families.contains(.highHeartRate))
        #expect(OnboardingNotificationGroup.band.families.contains(.battery))
        #expect(OnboardingCopy.Notifications.detail(for: .offUntilChosen).contains("heart rate"))
    }

    @Test
    func finishQuotesTheRecoveryConstantFromAnalytics() {
        let nights = WellnessAnalytics.readinessCompositeMinBaseline
        #expect(OnboardingFacts.recoveryLearningNights == nights)
        #expect(OnboardingCopy.Finish.baselineTitle(nights: nights) == "Recovery after \(nights) nights")
        #expect(OnboardingCopy.Finish.baselineDetail(nights: nights).contains("\(nights) nights"))
        #expect(OnboardingCopy.Finish.ringText(nights: nights) == "0/\(nights)")
    }

    @Test
    func sleepNeedStepUsesTheSettingsNameAndDefault() {
        #expect(OnboardingFacts.defaultSleepNeedHours == SleepNeed.defaultMinutes / 60)
        #expect(OnboardingCopy.SleepNeedStep.options.contains(OnboardingFacts.defaultSleepNeedHours))
        #expect(OnboardingCopy.Chrome.headerTitle(for: .sleepGoal) == "Sleep need")
        #expect(OnboardingCopy.SleepNeedStep.skipNote(defaultHours: 8).contains("8 hours"))
        #expect(OnboardingCopy.SleepNeedStep.skipNote(defaultHours: 8).contains("Settings, under Profile"))
        for option in OnboardingCopy.SleepNeedStep.options {
            #expect(OnboardingFlowController.sleepGoalRange.contains(option))
        }
    }

    @Test
    func timeZoneLineShowsTheCityAndOffset() throws {
        let january = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        #expect(OnboardingFacts.timeZoneLabel(try #require(TimeZone(identifier: "Australia/Perth")), at: january) == "Perth, GMT+8")
        #expect(OnboardingFacts.timeZoneLabel(try #require(TimeZone(identifier: "Asia/Kolkata")), at: january) == "Kolkata, GMT+5:30")
        #expect(OnboardingFacts.timeZoneLabel(try #require(TimeZone(identifier: "America/New_York")), at: january) == "New York, GMT-5")
        #expect(OnboardingFacts.timeZoneLabel(try #require(TimeZone(identifier: "Europe/London")), at: january) == "London, GMT")
        #expect(OnboardingCopy.Profile.timeZone("Perth, GMT+8") == "Time zone: Perth, GMT+8, from this iPhone.")
    }

    @Test
    func headerMetaMarksOptionalSteps() {
        #expect(OnboardingCopy.Chrome.meta(step: 2, of: 9, optional: false) == "STEP 2 OF 9")
        #expect(OnboardingCopy.Chrome.meta(step: 6, of: 9, optional: true) == "STEP 6 OF 9 · OPTIONAL")
        #expect(OnboardingStage.appleHealth.isOptional)
        #expect(!OnboardingStage.pairing.isOptional)
    }

    #if os(iOS)
    @Test
    func bandIntroMakesNoPricingPromise() {
        #expect(!BandIntroView.line.localizedCaseInsensitiveContains("free"))
        #expect(!BandIntroView.line.localizedCaseInsensitiveContains("forever"))
    }
    #endif

    // MARK: Helpers

    private func walk(_ controller: OnboardingFlowController, to target: OnboardingStage) async throws {
        while (await controller.snapshot()).stage != target {
            let stage = (await controller.snapshot()).stage
            switch stage {
            case .launching, .welcomeDisclosures, .whoopHandover, .prepareBand:
                _ = try await controller.advance()
            case .pairing:
                _ = try await controller.requestContextualPairing()
                _ = try await controller.advance()
            case .profileSetup:
                _ = try await controller.completeProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
            case .appleHealth:
                _ = try await controller.skipPermission(.appleHealth)
            case .notifications:
                _ = try await controller.skipPermission(.notifications)
            case .sleepGoal:
                _ = try await controller.skipSleepGoal()
            case .finish:
                _ = try await controller.finish()
            case .mainShell:
                Issue.record("Walked past \(target)")
                return
            }
        }
    }

    private func makeController(
        pairing: any ContextualPairingCoordinator = NoopPairingCoordinator(),
        permissions: any OnboardingPermissionCoordinator = NoopPermissionCoordinator()
    ) async throws -> OnboardingFlowController {
        try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(),
            profileRepository: InMemoryProfileRepository(dateProvider: FixedDateProvider(), uuidProvider: FixedUUIDProvider()),
            pairingCoordinator: pairing,
            permissionCoordinator: permissions,
            dateProvider: FixedDateProvider()
        )
    }
}

private actor RecordingPermissionCoordinator: OnboardingPermissionCoordinator {
    private(set) var requests: [OnboardingPermission] = []
    private let answer: OnboardingPermissionOutcome
    init(answer: OnboardingPermissionOutcome) { self.answer = answer }
    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionOutcome {
        requests.append(permission)
        return answer
    }
}

private struct FailingPairingCoordinator: ContextualPairingCoordinator {
    struct Failure: Error {}
    func requestPairing() async throws { throw Failure() }
}

private actor RecordingPairingCoordinator: ContextualPairingCoordinator {
    private(set) var requestCount = 0
    func requestPairing() async throws { requestCount += 1 }
}

private struct FixedDateProvider: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private actor FixedUUIDProvider: UUIDProviding {
    func nextUUID() -> UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
}
