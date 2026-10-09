import Foundation
import Testing
import DomainKit
import DeviceCenterKit
import SyncKit

struct DeviceCenterKitTests {
    @Test
    func stateMatrixIncludesReadyAndKeepsAbsenceDistinctFromMeasuredZero() {
        #expect(DeviceCenterUniversalState.allCases.count == 15)
        #expect(DeviceCenterStateFixtures.all.count == 15)
        #expect(Set(DeviceCenterStateFixtures.all.map { $0.state }).count == 15)

        let absent = DeviceCenterStateFixtures.all.first { $0.state == .absentMetric }
        let zero = DeviceCenterStateFixtures.all.first { $0.state == .measuredZero }
        #expect(absent?.status?.batteryPercent == .absent)
        #expect(zero?.status?.batteryPercent == .measured(0))
        #expect(absent?.status?.batteryPercent != zero?.status?.batteryPercent)
    }

    @Test
    func repositoryIsCanonicalSourceForIdentityAndStatus() async throws {
        let repository = InMemoryDeviceCenterRepository(
            identity: DeviceCenterStateFixtures.sampleDevice,
            status: DeviceCenterStateFixtures.populatedStatus
        )
        let view = try await DeviceCenterViewStateLoader.load(from: repository)
        #expect(view.universalState == .ready)
        #expect(view.message == "Connected and ready.")
        #expect(view.identity == DeviceCenterStateFixtures.sampleDevice)
        #expect(view.status == DeviceCenterStateFixtures.populatedStatus)
        #expect(view.status?.batteryPercent == .measured(78))
        #expect(view.forecastAccessibilityValue.contains("high"))
        #expect(view.status?.charging == false)
        #expect(view.status?.wristState == .worn)
        #expect(view.status?.freshness != .absent)
        #expect(view.status?.lastPacketAt != nil)
        #expect(view.status?.historyCommitAt != nil)
        #expect(view.status?.completedSyncAt != nil)
        #expect(view.status?.storedAt != nil)
        #expect(view.capabilityRows.count == DeviceAction.allCases.count)
        #expect(view.statusAccessibilityLabel.contains("Battery 78 percent measured"))
        #expect(!view.statusAccessibilityLabel.contains("partialData"))
    }

    @Test
    func connectedStatusWithMissingReadingsStaysPartial() async throws {
        let repository = InMemoryDeviceCenterRepository(
            identity: DeviceCenterStateFixtures.sampleDevice,
            status: DeviceStatusSnapshot(connection: .connected, bluetooth: .poweredOn, batteryPercent: .measured(78))
        )
        let view = try await DeviceCenterViewStateLoader.load(from: repository)
        #expect(view.universalState == .partialData)
        #expect(view.message == nil)
    }

    @Test
    func everyFixtureLoadsItsDeclaredUniversalState() async throws {
        for fixture in DeviceCenterStateFixtures.all {
            if fixture.state == .loading {
                #expect(DeviceCenterViewStateLoader.loading.universalState == .loading)
                continue
            }
            let repository = InMemoryDeviceCenterRepository(identity: fixture.identity, status: fixture.status)
            let view = try await DeviceCenterViewStateLoader.load(from: repository)
            #expect(view.universalState == fixture.state, "Fixture \(fixture.state.rawValue) should remain distinct")
        }
    }

    @Test
    func unsupportedCapabilityNeverReachesWriter() async throws {
        let identity = DeviceIdentity(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
            generation: .stableGen4,
            modelConfidence: .fixtureVerified,
            capabilities: DeviceCapabilityMatrix(supportedActions: [.manualSync])
        )
        let repository = InMemoryDeviceCenterRepository(identity: identity)
        let writer = RecordingDeviceCommandWriter()
        let service = CapabilityGatedDeviceActionService(repository: repository, writer: writer)

        await #expect(throws: DeviceActionError.unsupported(.rename)) {
            _ = try await service.perform(DeviceCommand(action: .rename, argument: "New name"))
        }
        #expect(await writer.commands.isEmpty)
    }

    @Test
    func unsupportedActionsAreUnavailableInViewStateAndNeverReachWriter() async throws {
        let identity = DeviceIdentity(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
            generation: .stableGen4,
            modelConfidence: .fixtureVerified,
            capabilities: DeviceCapabilityMatrix(supportedActions: [.manualSync])
        )
        let repository = InMemoryDeviceCenterRepository(identity: identity)
        let writer = RecordingDeviceCommandWriter()
        let service = CapabilityGatedDeviceActionService(repository: repository, writer: writer)
        let view = try await DeviceCenterViewStateLoader.load(from: repository)

        for action in DeviceAction.allCases where action != .manualSync {
            #expect(!view.isActionAvailable(action))
            await #expect(throws: DeviceActionError.unsupported(action)) {
                _ = try await service.perform(DeviceCommand(action: action, argument: action == .rename ? "Valid" : nil))
            }
        }
        #expect(await writer.commands.isEmpty)
    }

    @Test
    func renameValidatesBeforeWriterAndManualSyncPassesWhenAllowed() async throws {
        let identity = DeviceCenterStateFixtures.sampleDevice
        let repository = InMemoryDeviceCenterRepository(identity: identity)
        let writer = RecordingDeviceCommandWriter()
        let service = CapabilityGatedDeviceActionService(repository: repository, writer: writer)

        await #expect(throws: DeviceActionError.invalidArgument(.rename)) {
            _ = try await service.perform(DeviceCommand(action: .rename, argument: "   "))
        }
        #expect(await writer.commands.isEmpty)

        _ = try await service.perform(.manualSync)
        #expect(await writer.commands == [DeviceCommand(action: .manualSync)])

        _ = try await service.perform(DeviceCommand(action: .rename, argument: " Bedroom strap "))
        #expect((try await repository.readIdentity())?.displayName == "Bedroom strap")
    }

    @Test
    func alarmSetupPersistsLocallyWithoutWritingToBand() async throws {
        let repository = InMemoryDeviceCenterRepository(identity: DeviceCenterStateFixtures.sampleDevice)
        let writer = RecordingDeviceCommandWriter()
        let service = DeviceAlarmSetupService(repository: repository)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 420,
            endMinute: 450,
            weekdays: [.monday, .wednesday]
        )

        _ = try await service.save(configuration)
        #expect(try await repository.readAlarmConfiguration() == configuration)
        #expect(await writer.commands.isEmpty)
    }

    @Test
    func diagnosticExportIsDeterministicAndCapabilityRowsAreIndividual() async throws {
        let identity = DeviceCenterStateFixtures.sampleDevice
        let export = DeviceDiagnosticExporter.make(
            identity: identity,
            status: DeviceCenterStateFixtures.populatedStatus,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let first = try DeviceDiagnosticExporter.encode(export)
        let second = try DeviceDiagnosticExporter.encode(export)
        #expect(first == second)

        let mixed = DeviceCapabilityMatrix(
            supportedActions: [.manualSync],
            statuses: [.rename: .unsupported, .findMyStrap: .supported]
        )
        #expect(mixed.status(for: .manualSync) == .supported)
        #expect(mixed.status(for: .rename) == .unsupported)
        #expect(mixed.status(for: .torch) == .unknown)
    }

    @Test
    func firstSessionDiagnosticsRenderEveryMilestoneKeepFiveErrorsAndExportRedactedText() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var events: [ConnectionDiagnosticsEvent] = [
            .init(kind: .advertisementSeen, timestamp: base, generation: 2, label: "Advertisement", detail: "WHOOP 4A0B; saved identifier matched"),
            .init(kind: .gattDiscovery, timestamp: base.addingTimeInterval(1), generation: 2, label: "GATT discovery", detail: "Harvard service and four characteristics found"),
            .init(kind: .notificationSubscription, timestamp: base.addingTimeInterval(2), generation: 2, label: "Response notifications", detail: "Subscribed"),
            .init(kind: .notificationSubscription, timestamp: base.addingTimeInterval(3), generation: 2, label: "Event notifications", detail: "Subscribed"),
            .init(kind: .notificationSubscription, timestamp: base.addingTimeInterval(4), generation: 2, label: "Data notifications", detail: "Subscribed"),
            .init(kind: .clockSet, timestamp: base.addingTimeInterval(5), generation: 2, label: "SET_CLOCK", detail: "Write response received"),
            .init(kind: .clockGet, timestamp: base.addingTimeInterval(6), generation: 2, label: "GET_CLOCK", detail: "Readback delta +0.125 s"),
            .init(kind: .initializationWriteResponse, timestamp: base.addingTimeInterval(7), generation: 2, label: "HELLO", detail: "Write response received"),
            .init(kind: .historyMetadataReceived, timestamp: base.addingTimeInterval(8), generation: 2, label: "History metadata", detail: "Chunk start"),
            .init(kind: .historyCommitted, timestamp: base.addingTimeInterval(9), generation: 2, correlationID: "do-not-export-token-DEADBEEF"),
            .init(kind: .acknowledgementEmitted, timestamp: base.addingTimeInterval(10), generation: 2, correlationID: "do-not-export-token-DEADBEEF")
        ]
        for index in 0..<7 {
            events.append(.init(
                kind: .error,
                timestamp: base.addingTimeInterval(Double(11 + index)),
                generation: 2,
                label: "Protocol error",
                detail: "Error \(index)"
            ))
        }
        let report = DeviceFirstSessionDiagnostics(
            snapshot: ConnectionDiagnosticsSnapshot(events: events, violations: [])
        )

        #expect(Set(report.rows.map(\.category)) == Set(DeviceFirstSessionDiagnosticCategory.allCases))
        #expect(report.rows.filter { $0.category == .notificationSubscription }.count == 3)
        #expect(report.committedChunkCount == 1)
        #expect(report.acknowledgedChunkCount == 1)
        #expect(report.errors.map(\.detail) == ["Error 2", "Error 3", "Error 4", "Error 5", "Error 6"])

        let text = DeviceFirstSessionDiagnosticsTextExporter.make(
            report: report,
            deviceName: "WHOOP 4.0",
            generatedAt: base.addingTimeInterval(30)
        )
        #expect(text.contains("First-session diagnostics"))
        #expect(text.contains("History chunks committed: 1"))
        #expect(text.contains("History chunks ACKed: 1"))
        #expect(text.contains("Readback delta +0.125 s"))
        #expect(!text.contains("DEADBEEF"))
        #expect(!text.contains("do-not-export-token"))
    }

    @Test
    func connectedMixedCapabilitiesFixtureRendersEachCapabilityAndFailsClosed() async throws {
        let fixture = DeviceCenterStateFixtures.connectedMixedCapabilities
        let identity = try #require(fixture.identity)
        let status = try #require(fixture.status)
        let repository = InMemoryDeviceCenterRepository(identity: identity, status: status)
        let view = try await DeviceCenterViewStateLoader.load(from: repository)
        let rows = Dictionary(uniqueKeysWithValues: view.capabilityRows.map { ($0.action, $0) })

        #expect(identity.generation == .betaGen5)
        #expect(identity.betaStatus == "capability-gated")
        #expect(view.universalState == .ready)
        #expect(rows.count == DeviceAction.allCases.count)
        #expect(rows[.manualSync]?.status == .supported)
        #expect(rows[.manualSync]?.presentationTitle == "Available")
        #expect(rows[.findMyStrap]?.status == .unsupported)
        #expect(rows[.findMyStrap]?.presentationTitle == "Not supported by this strap")
        #expect(rows[.rePair]?.status == .unknown)
        #expect(rows[.rePair]?.presentationTitle == "Not verified")
        #expect(view.isActionAvailable(.manualSync))
        #expect(!view.isActionAvailable(.findMyStrap))
        #expect(!view.isActionAvailable(.rePair))
        #expect(rows[.findMyStrap]?.accessibilityLabel == "Find my strap, Not supported by this strap")
        #expect(rows[.rePair]?.accessibilityLabel == "Pair again, Not verified")

        let writer = RecordingDeviceCommandWriter()
        let service = CapabilityGatedDeviceActionService(repository: repository, writer: writer)
        await #expect(throws: DeviceActionError.unsupported(.findMyStrap)) {
            _ = try await service.perform(.findMyStrap)
        }
        await #expect(throws: DeviceActionError.unsupported(.rePair)) {
            _ = try await service.perform(.rePair)
        }
        #expect(await writer.commands.isEmpty)
    }

    @Test
    func findMyStrapIsDebouncedAndGuidanceUsesRSSIChange() async throws {
        let identity = DeviceCenterStateFixtures.sampleDevice
        let repository = InMemoryDeviceCenterRepository(identity: identity)
        let writer = RecordingDeviceCommandWriter()
        let service = CapabilityGatedDeviceActionService(
            repository: repository,
            writer: writer,
            dateProvider: ManualDateProvider(),
            debounceInterval: 5
        )

        _ = try await service.perform(.findMyStrap)
        await #expect(throws: DeviceActionError.debounced(.findMyStrap)) {
            _ = try await service.perform(.findMyStrap)
        }
        #expect(await writer.commands.count == 1)
        #expect(FindMyStrapGuidanceCalculator.guidance(currentRSSI: -55, previousRSSI: -65) == .warmer)
        #expect(FindMyStrapGuidanceCalculator.guidance(currentRSSI: -70, previousRSSI: -60) == .colder)
        #expect(FindMyStrapGuidanceCalculator.guidance(currentRSSI: nil, previousRSSI: nil) == .unavailable)
        #expect(FindMyStrapGuidanceCalculator.feedback(currentRSSI: -55, previousRSSI: -65).haptic == .intensify)
    }

    @Test
    func noDeviceFailsClosed() async {
        let service = CapabilityGatedDeviceActionService(
            repository: InMemoryDeviceCenterRepository(),
            writer: RecordingDeviceCommandWriter()
        )
        await #expect(throws: DeviceActionError.noDevice) {
            _ = try await service.perform(.manualSync)
        }
    }

    @Test
    func forgetAndDeprovisionRemoveCanonicalIdentityAndStatus() async throws {
        let repository = InMemoryDeviceCenterRepository(
            identity: DeviceCenterStateFixtures.sampleDevice,
            status: DeviceCenterStateFixtures.populatedStatus,
            alarmConfiguration: StrapAlarmConfiguration(isEnabled: false)
        )
        try await repository.forgetBand()
        #expect(try await repository.readIdentity() == nil)
        #expect(try await repository.readStatus() == nil)
        #expect(try await repository.readAlarmConfiguration() == nil)

        try await repository.saveIdentity(DeviceCenterStateFixtures.sampleDevice)
        try await repository.saveStatus(DeviceCenterStateFixtures.populatedStatus)
        try await repository.deprovision()
        #expect(try await repository.readIdentity() == nil)
        #expect(try await repository.readStatus() == nil)
    }

    @Test
    func deviceAccessibilityContractCoversPackageScreens() {
        let contract = DeviceAccessibilityContract()
        #expect(contract.supportsDynamicType)
        #expect(contract.supportsReduceMotion)
        #expect(contract.usesSemanticVoiceOverLabels)
        #expect(DeviceAccessibilityContract.minimumTouchTarget >= 44)
        #expect(DeviceAccessibilityContract.requiredScreenIdentifiers.contains("device-export-diagnostics"))
        #expect(DeviceCenterTelemetryPolicy.emitsEventsBeforeConsent == false)
    }

    @Test
    func phase13ActionScreensUseCanonicalRepositoryAndIncludeReady() async throws {
        #expect(DeviceActionScreenStateFixtures.accessibilityIdentifiers.count == 3)
        #expect(DeviceActionScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 15 })
        #expect(DeviceActionScreenStateFixtures.all.count == 45)

        let repository = InMemoryDeviceCenterRepository(
            identity: DeviceCenterStateFixtures.sampleDevice,
            status: DeviceCenterStateFixtures.populatedStatus
        )
        let readback = RecordingDeviceActionReadback()
        await readback.set(.confirmed, for: .findMyStrap)
        let projection = try await DeviceActionScreenProjectionLoader.load(
            screen: .findMyStrap,
            repository: repository,
            readback: readback
        )
        #expect(projection.identity == DeviceCenterStateFixtures.sampleDevice)
        #expect(projection.capability == .supported)
        #expect(projection.readback == .confirmed)
        #expect(projection.universalState == .ready)
        #expect(projection.accessibilityIdentifier == "find-my-strap-screen")
        #expect(projection.accessibilitySummary.hasPrefix("Find my strap."))
        #expect(!projection.accessibilitySummary.contains("find-my-strap-screen"))

        let alarmRecovery = try #require(
            DeviceActionScreenStateFixtures.statesByScreen[.strapAlarmSetup]?.first {
                $0.condition == .strapAlarmRecovery
            }
        )
        #expect(alarmRecovery.universalState == .recoverableError)
        #expect(alarmRecovery.readback.isConfirmed == false)

        let gestureUnsupported = try #require(
            DeviceActionScreenStateFixtures.statesByScreen[.gestureMapping]?.first {
                $0.condition == .gestureCapabilityUnsupported
            }
        )
        #expect(gestureUnsupported.universalState == .unsupportedHardware)
        #expect(gestureUnsupported.capability == .unsupported)
        #expect(gestureUnsupported.readback.isConfirmed == false)

        let absent = try #require(
            DeviceActionScreenStateFixtures.statesByScreen[.findMyStrap]?.first {
                $0.universalState == .absentMetric
            }
        )
        let zero = try #require(
            DeviceActionScreenStateFixtures.statesByScreen[.findMyStrap]?.first {
                $0.universalState == .measuredZero
            }
        )
        #expect(absent.accessibilitySummary != zero.accessibilitySummary)
    }

    @Test
    func missingWriterAndReadbackRemainExplicitlyUnavailable() async throws {
        let repository = InMemoryDeviceCenterRepository(identity: DeviceCenterStateFixtures.sampleDevice)
        let service = CapabilityGatedDeviceActionService(repository: repository, writer: NoopDeviceCommandWriter())
        await #expect(throws: DeviceActionError.writerUnavailable(.manualSync)) {
            _ = try await service.perform(.manualSync)
        }

        let readback = UnavailableDeviceActionReadback()
        let state = await readback.state(for: .strapAlarmSetup)
        #expect(state == .unavailable(reason: "No verified device readback adapter is available."))
        #expect(!state.isConfirmed)

        let recording = RecordingDeviceActionReadback()
        #expect(!(await recording.state(for: .findMyStrap)).isConfirmed)
        await recording.set(.confirmed, for: .findMyStrap)
        #expect((await recording.state(for: .findMyStrap)).isConfirmed)
    }

    @Test
    func strapAlarmWorkflowRequiresExactBandReadbackBeforeTestAndDisable() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualDateProvider(value: now)
        let transport = AlarmTransportFixture(
            clock: StrapAlarmClockReading(
                generation: 7,
                bandDate: now.addingTimeInterval(0.25),
                sampledAt: now
            )
        )
        let repository = InMemoryDeviceCenterRepository()
        let workflow = StrapAlarmWorkflow(
            transport: transport,
            repository: repository,
            capabilityProvider: StaticDeviceActionCapabilityProvider(
                supportedActions: [.strapAlarmSetup, .strapAlarmReadback]
            ),
            dateProvider: clock,
            maximumClockOffset: 1
        )
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 420,
            endMinute: 450,
            weekdays: [.monday]
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let hostFireDate = now.addingTimeInterval(3_600)

        let correlation = try await workflow.correlateClock(at: now)
        #expect(correlation.generation == 7)
        #expect(correlation.offsetSeconds == 0.25)
        let request = try await workflow.set(
            StrapAlarmSchedule(configuration: configuration, hostFireDate: hostFireDate),
            requestID: requestID
        )
        #expect(await workflow.state == .awaitingReadback(request))
        await #expect(throws: StrapAlarmWorkflowError.invalidTransition(
            operation: "test the strap alarm",
            state: .awaitingReadback(request)
        )) {
            _ = try await workflow.test()
        }
        await transport.setReadback(StrapAlarmDeviceReadback(
            requestID: requestID,
            generation: 7,
            configuration: configuration,
            bandFireDate: request.bandFireDate,
            confirmedAt: now.addingTimeInterval(1)
        ))
        _ = try await workflow.readback()
        let readback = await transport.readbackValue()
        #expect(readback != nil)
        if let readback {
            #expect(await workflow.state == .readyToTest(request, readback))
        }
        _ = try await workflow.test()
        if let readback {
            #expect(await workflow.state == .tested(request, readback))
        }
        _ = try await workflow.disable()
        #expect(await workflow.state == .disabled(request))
        #expect(try await repository.readAlarmConfiguration() == configuration)
        #expect(await transport.calls() == ["clock", "set", "read", "test", "disable"])
    }

    @Test
    func strapAlarmMismatchAndFailedSetEnterRecoveryWithoutFalseSuccess() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualDateProvider(value: now)
        let transport = AlarmTransportFixture(
            clock: StrapAlarmClockReading(generation: 8, bandDate: now, sampledAt: now),
            setFailure: .set
        )
        let alarmCapabilities = StaticDeviceActionCapabilityProvider(
            supportedActions: [.strapAlarmSetup, .strapAlarmReadback]
        )
        let workflow = StrapAlarmWorkflow(
            transport: transport,
            capabilityProvider: alarmCapabilities,
            dateProvider: clock
        )
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 500,
            endMinute: 530,
            weekdays: [.tuesday]
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let schedule = StrapAlarmSchedule(configuration: configuration, hostFireDate: now.addingTimeInterval(600))
        _ = try await workflow.correlateClock(at: now)
        await #expect(throws: StrapAlarmWorkflowError.setFailed("set")) {
            _ = try await workflow.set(schedule, requestID: requestID)
        }
        guard case .recoveryRequired(.setFailed) = await workflow.state else {
            Issue.record("A failed set must require recovery")
            return
        }
        #expect(await workflow.recover() == .resetForRetry)
        #expect(await workflow.state == .idle)

        let secondTransport = AlarmTransportFixture(
            clock: StrapAlarmClockReading(generation: 8, bandDate: now, sampledAt: now)
        )
        let secondWorkflow = StrapAlarmWorkflow(
            transport: secondTransport,
            capabilityProvider: alarmCapabilities,
            dateProvider: clock
        )
        _ = try await secondWorkflow.correlateClock(at: now)
        let request = try await secondWorkflow.set(schedule, requestID: requestID)
        await secondTransport.setReadback(StrapAlarmDeviceReadback(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000199")!,
            generation: 8,
            configuration: configuration,
            bandFireDate: request.bandFireDate,
            confirmedAt: now
        ))
        await #expect(throws: StrapAlarmWorkflowError.readbackMismatch) {
            _ = try await secondWorkflow.readback()
        }
        #expect(await secondWorkflow.state == .recoveryRequired(.readbackMismatch))
        #expect(await secondWorkflow.recover() == .resetForRetry)
        #expect(await secondWorkflow.state == .idle)
    }

    @Test
    func strapAlarmRejectsClockDriftAndUnavailableProductionTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualDateProvider(value: now)
        let drifted = AlarmTransportFixture(
            clock: StrapAlarmClockReading(generation: 9, bandDate: now.addingTimeInterval(3), sampledAt: now)
        )
        let alarmCapabilities = StaticDeviceActionCapabilityProvider(
            supportedActions: [.strapAlarmSetup, .strapAlarmReadback]
        )
        let workflow = StrapAlarmWorkflow(
            transport: drifted,
            capabilityProvider: alarmCapabilities,
            dateProvider: clock,
            maximumClockOffset: 1
        )
        await #expect(throws: StrapAlarmWorkflowError.clockOutOfTolerance(3)) {
            _ = try await workflow.correlateClock(at: now)
        }
        #expect(await workflow.state == .recoveryRequired(.clockOutOfTolerance(3)))
        #expect(await drifted.calls() == ["clock"])

        let unavailable = StrapAlarmWorkflow(
            transport: UnavailableStrapAlarmTransport(),
            capabilityProvider: alarmCapabilities,
            dateProvider: clock
        )
        await #expect(throws: StrapAlarmWorkflowError.clockUnavailable("No verified strap alarm command/readback adapter is available.")) {
            _ = try await unavailable.correlateClock(at: now)
        }
        guard case .recoveryRequired(.clockReadFailed) = await unavailable.state else {
            Issue.record("Unavailable alarm transport must remain fail-closed")
            return
        }
    }

    @Test
    func strapAlarmCopyNeverClaimsSleepStageWakeWindowBehavior() {
        let strings = [
            StrapAlarmWorkflowError.invalidSchedule.errorDescription,
            StrapAlarmWorkflowError.clockUnavailable("unavailable").errorDescription,
            StrapAlarmWorkflowError.readbackUnavailable.errorDescription,
            StrapAlarmWorkflowError.readbackMismatch.errorDescription,
            StrapAlarmWorkflowError.testFailed("failed").errorDescription,
            StrapAlarmWorkflowError.disableFailed("failed").errorDescription,
            DeviceConfigurationError.invalidAlarmConfiguration.errorDescription
        ].compactMap { $0?.lowercased() }
        let forbidden = ["sleep stage", "sleep-stage", "wake window", "wake-window"]
        #expect(strings.allSatisfy { value in forbidden.allSatisfy { !value.contains($0) } })
        #expect(strings.allSatisfy { $0.contains("strap alarm") })
    }

    @Test
    func findMyStrapConfirmsOnlyMatchingExecutedReadback() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let generation = GenerationFixture(value: 12)
        let transport = FindMyStrapTransportFixture()
        let workflow = FindMyStrapWorkflow(
            transport: transport,
            generationProvider: generation,
            capabilityProvider: StaticDeviceActionCapabilityProvider(supportedActions: [.findMyStrap]),
            dateProvider: ManualDateProvider(value: now)
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let request = try await workflow.request(generation: 12, requestID: requestID, at: now)
        #expect(await workflow.state == .awaitingReadback(request))
        await transport.setReadback(FindMyStrapReadback(
            requestID: requestID,
            generation: 12,
            confirmedAt: now,
            executed: false
        ))
        await #expect(throws: FindMyStrapWorkflowError.readbackNotConfirmed) {
            _ = try await workflow.confirmReadback()
        }
        #expect(await workflow.state == .recoveryRequired("The band did not confirm Find My Strap execution."))
        await workflow.resetForRetry()

        let retry = try await workflow.request(generation: 12, requestID: requestID, at: now)
        await transport.setReadback(FindMyStrapReadback(
            requestID: retry.requestID,
            generation: retry.generation,
            confirmedAt: now,
            executed: true
        ))
        let confirmed = try await workflow.confirmReadback()
        #expect(confirmed.executed)
        #expect(await workflow.state == .confirmed(retry, confirmed))
        #expect(await transport.calls() == ["request", "readback", "request", "readback"])
    }

    @Test
    func doubleTapDispatchesOnlyTypedJournalOrWorkoutActionsAndRejectsReplay() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = ManualDateProvider(value: now)
        let generation = GenerationFixture(value: 13)
        let journal = JournalMarkerSinkFixture()
        let workout = WorkoutActionSinkFixture()
        let dispatcher = DeviceGestureActionDispatcher(
            generationProvider: generation,
            dateProvider: date,
            capabilityProvider: StaticDeviceGestureCapabilityProvider(
                supportedActions: [.markMoment, .startWorkout, .pauseWorkout, .finishWorkout]
            ),
            journalSink: journal,
            workoutSink: workout,
            maximumAge: 5
        )
        let markerID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let markerEvent = DeviceGestureEvent(eventID: markerID, gesture: .doubleTap, generation: 13, occurredAt: now)
        _ = try await dispatcher.dispatch(markerEvent, action: .markMoment)
        #expect(await journal.markers() == [DeviceJournalMarker(eventID: markerID, generation: 13, occurredAt: now)])
        await #expect(throws: DeviceGestureDispatchError.replayed) {
            _ = try await dispatcher.dispatch(markerEvent, action: .markMoment)
        }

        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let workoutEvent = DeviceGestureEvent(eventID: workoutID, gesture: .doubleTap, generation: 13, occurredAt: now)
        _ = try await dispatcher.dispatch(workoutEvent, action: .startWorkout)
        #expect(await workout.requests() == [DeviceWorkoutActionRequest(
            eventID: workoutID,
            generation: 13,
            occurredAt: now,
            action: .startWorkout
        )])
        let pauseID = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
        _ = try await dispatcher.dispatch(
            DeviceGestureEvent(eventID: pauseID, gesture: .doubleTap, generation: 13, occurredAt: now),
            action: .pauseWorkout
        )
        let finishID = UUID(uuidString: "00000000-0000-0000-0000-000000000109")!
        _ = try await dispatcher.dispatch(
            DeviceGestureEvent(eventID: finishID, gesture: .doubleTap, generation: 13, occurredAt: now),
            action: .finishWorkout
        )
        #expect(await workout.requests().map(\.action) == [.startWorkout, .pauseWorkout, .finishWorkout])
        let unsupported = DeviceGestureEvent(eventID: UUID(), gesture: .longPress, generation: 13, occurredAt: now)
        await #expect(throws: DeviceGestureDispatchError.unsupportedGesture(.longPress)) {
            _ = try await dispatcher.dispatch(unsupported, action: .markMoment)
        }
    }

    @Test
    func doubleTapFenceRejectsStaleOldFutureAndMissingDestinations() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = ManualDateProvider(value: now)
        let generation = GenerationFixture(value: 14)
        let dispatcher = DeviceGestureActionDispatcher(
            generationProvider: generation,
            dateProvider: date,
            capabilityProvider: StaticDeviceGestureCapabilityProvider(
                supportedActions: [.markMoment]
            ),
            maximumAge: 5
        )
        await #expect(throws: DeviceGestureDispatchError.sinkUnavailable(.markMoment)) {
            _ = try await dispatcher.dispatch(
                DeviceGestureEvent(eventID: UUID(), gesture: .doubleTap, generation: 14, occurredAt: now),
                action: .markMoment
            )
        }
        await #expect(throws: DeviceGestureDispatchError.staleGeneration) {
            _ = try await dispatcher.dispatch(
                DeviceGestureEvent(eventID: UUID(), gesture: .doubleTap, generation: 99, occurredAt: now),
                action: .markMoment
            )
        }
        let unsupported = DeviceGestureEvent(
            eventID: UUID(),
            gesture: .doubleTap,
            generation: 14,
            occurredAt: now
        )
        await #expect(throws: DeviceGestureDispatchError.unsupportedAction(.finishWorkout)) {
            _ = try await dispatcher.dispatch(unsupported, action: .finishWorkout)
        }
        await #expect(throws: DeviceGestureDispatchError.eventTooOld) {
            _ = try await dispatcher.dispatch(
                DeviceGestureEvent(eventID: UUID(), gesture: .doubleTap, generation: 14, occurredAt: now.addingTimeInterval(-6)),
                action: .markMoment
            )
        }
        await #expect(throws: DeviceGestureDispatchError.eventFromFuture) {
            _ = try await dispatcher.dispatch(
                DeviceGestureEvent(eventID: UUID(), gesture: .doubleTap, generation: 14, occurredAt: now.addingTimeInterval(1)),
                action: .markMoment
            )
        }
    }

    @Test
    func phoneActionsRequireCurrentGenerationRecencyDebounceAndUniqueEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = ManualDateProvider(value: now)
        let generation = GenerationFixture(value: 15)
        let sink = PhoneActionSinkFixture()
        let dispatcher = DevicePhoneActionDispatcher(
            generationProvider: generation,
            dateProvider: date,
            capabilityProvider: StaticDevicePhoneCapabilityProvider(
                supportedActions: [.ringPhone, .torch]
            ),
            sink: sink,
            maximumAge: 5,
            debounceInterval: 1
        )
        let ringID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let ring = DevicePhoneActionRequest(eventID: ringID, action: .ringPhone, generation: 15, occurredAt: now)
        _ = try await dispatcher.dispatch(ring)
        #expect(await sink.requests() == [ring])
        await #expect(throws: DevicePhoneActionDispatchError.replayed) {
            _ = try await dispatcher.dispatch(ring)
        }
        let debounced = DevicePhoneActionRequest(eventID: UUID(), action: .ringPhone, generation: 15, occurredAt: now)
        await #expect(throws: DevicePhoneActionDispatchError.debounced(.ringPhone)) {
            _ = try await dispatcher.dispatch(debounced)
        }
        date.advance(by: 1.1)
        let torch = DevicePhoneActionRequest(eventID: UUID(), action: .torch, generation: 15, occurredAt: now.addingTimeInterval(1.1))
        _ = try await dispatcher.dispatch(torch)
        #expect(await sink.requests() == [ring, torch])

        await generation.set(16)
        let stale = DevicePhoneActionRequest(eventID: UUID(), action: .torch, generation: 15, occurredAt: now.addingTimeInterval(1.1))
        await #expect(throws: DevicePhoneActionDispatchError.staleGeneration) {
            _ = try await dispatcher.dispatch(stale)
        }
        let old = DevicePhoneActionRequest(eventID: UUID(), action: .torch, generation: 16, occurredAt: now.addingTimeInterval(-10))
        await #expect(throws: DevicePhoneActionDispatchError.eventTooOld) {
            _ = try await dispatcher.dispatch(old)
        }
    }

    @Test
    func phoneActionsRemainUnavailableWithoutVerifiedSink() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dispatcher = DevicePhoneActionDispatcher(
            generationProvider: GenerationFixture(value: 17),
            dateProvider: ManualDateProvider(value: now),
            capabilityProvider: StaticDevicePhoneCapabilityProvider(supportedActions: [.ringPhone]),
            sink: UnavailableDevicePhoneActionSink()
        )
        let request = DevicePhoneActionRequest(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!,
            action: .ringPhone,
            generation: 17,
            occurredAt: now
        )
        await #expect(throws: DevicePhoneActionDispatchError.unavailable("No verified phone action adapter is available.")) {
            _ = try await dispatcher.dispatch(request)
        }
    }
}

private final class ManualDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(value: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.value = value
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

private enum FixtureFailure: Error, Equatable, Sendable {
    case set
    case readback
    case test
    case disable
}

private actor AlarmTransportFixture: StrapAlarmTransport {
    private let clock: StrapAlarmClockReading
    private let setFailure: FixtureFailure?
    private var failure: FixtureFailure?
    private var value: StrapAlarmDeviceReadback?
    private var history: [String] = []

    init(
        clock: StrapAlarmClockReading,
        setFailure: FixtureFailure? = nil,
        failure: FixtureFailure? = nil
    ) {
        self.clock = clock
        self.setFailure = setFailure
        self.failure = failure
    }

    func readBandClock() async throws -> StrapAlarmClockReading {
        history.append("clock")
        return clock
    }

    func setAlarm(_ request: StrapAlarmSetRequest) async throws {
        history.append("set")
        if let setFailure { throw setFailure }
        if failure == .set { failure = nil; throw FixtureFailure.set }
        _ = request
    }

    func readAlarm() async throws -> StrapAlarmDeviceReadback? {
        history.append("read")
        if failure == .readback { failure = nil; throw FixtureFailure.readback }
        return value
    }

    func testAlarm() async throws {
        history.append("test")
        if failure == .test { failure = nil; throw FixtureFailure.test }
    }

    func disableAlarm() async throws {
        history.append("disable")
        if failure == .disable { failure = nil; throw FixtureFailure.disable }
    }

    func setReadback(_ value: StrapAlarmDeviceReadback?) { self.value = value }
    func readbackValue() -> StrapAlarmDeviceReadback? { value }
    func calls() -> [String] { history }
}

private actor FindMyStrapTransportFixture: FindMyStrapTransport {
    private var value: FindMyStrapReadback?
    private var history: [String] = []

    func requestFindMyStrap(_ request: FindMyStrapRequest) async throws {
        _ = request
        history.append("request")
    }

    func readFindMyStrap(_ request: FindMyStrapRequest) async throws -> FindMyStrapReadback? {
        _ = request
        history.append("readback")
        return value
    }

    func setReadback(_ value: FindMyStrapReadback?) { self.value = value }
    func calls() -> [String] { history }
}

private actor GenerationFixture: DeviceRuntimeGenerationProvider {
    private var value: UInt64?

    init(value: UInt64?) { self.value = value }
    func currentGeneration() async -> UInt64? { value }
    func set(_ value: UInt64?) { self.value = value }
}

private actor JournalMarkerSinkFixture: DeviceJournalMarkerSink {
    private var values: [DeviceJournalMarker] = []
    func append(_ marker: DeviceJournalMarker) async throws { values.append(marker) }
    func markers() -> [DeviceJournalMarker] { values }
}

private actor WorkoutActionSinkFixture: DeviceWorkoutActionSink {
    private var values: [DeviceWorkoutActionRequest] = []
    func perform(_ request: DeviceWorkoutActionRequest) async throws { values.append(request) }
    func requests() -> [DeviceWorkoutActionRequest] { values }
}

private actor PhoneActionSinkFixture: DevicePhoneActionSink {
    private var values: [DevicePhoneActionRequest] = []
    func perform(_ request: DevicePhoneActionRequest) async throws { values.append(request) }
    func requests() -> [DevicePhoneActionRequest] { values }
}
