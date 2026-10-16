import Photos
import SwiftUI

/// 선택한 혈당 측정 시각 전후 1시간에 찍은 사진을 보여주고,
/// 하나를 골라 간단한 메모와 함께 저장하는 시트.
struct MealPhotoSheet: View {
    let pointDate: Date
    /// (사진 자산 식별자, 메모, 탄수화물 g). 사진 없이 메모나 탄수화물만 저장할 수도 있다.
    let onSave: (String?, String, Double?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var assets: [PHAsset] = []
    @State private var selectedAssetID: String?
    @State private var memo = ""
    @State private var carbsText = ""

    /// 측정 시각 전후로 사진을 찾는 범위.
    private static let window: TimeInterval = 3600

    /// 입력한 탄수화물(g). 숫자가 아니거나 0 이하이면 없는 것으로 본다.
    private var carbsGrams: Double? {
        guard let value = Double(carbsText.replacingOccurrences(of: ",", with: ".")),
              value > 0
        else { return nil }
        return value
    }

    private var canSave: Bool {
        selectedAssetID != nil
            || !memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || carbsGrams != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(Self.timeLabel(pointDate)) 전후 1시간에 찍은 사진")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                photoSection

                VStack(alignment: .leading, spacing: 8) {
                    TextField("메모 (예: 김치찌개, 라떼)", text: $memo, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(10)
                        .background(
                            Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))

                    HStack(spacing: 8) {
                        TextField("탄수화물 (선택)", text: $carbsText)
                            .keyboardType(.decimalPad)
                            .padding(10)
                            .background(
                                Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                            .frame(maxWidth: 160)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }

                    Text("탄수화물을 입력하면 건강 앱에 섭취 기록으로 저장됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .padding(.top, 8)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("식사 사진·메모")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(
                            selectedAssetID,
                            memo.trimmingCharacters(in: .whitespacesAndNewlines),
                            carbsGrams)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .task {
            await loadPhotos()
        }
    }

    // MARK: - 사진 그리드

    @ViewBuilder
    private var photoSection: some View {
        switch authStatus {
        case .notDetermined:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .denied, .restricted:
            ContentUnavailableView {
                Label("사진 접근 권한 없음", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("설정에서 사진 접근을 허용하면 이 시간대에 찍은 사진을 불러올 수 있습니다.\n지금은 메모와 탄수화물만 저장할 수 있습니다.")
            } actions: {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            if assets.isEmpty {
                ContentUnavailableView(
                    "이 시간대 사진 없음",
                    systemImage: "photo",
                    description: Text("이 시간대에 찍은 사진이 없습니다. 메모와 탄수화물만 저장할 수 있습니다."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                photoGrid
            }
        }
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                spacing: 4
            ) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    assetCell(asset)
                }
            }
            .padding(.horizontal)
        }
    }

    private func assetCell(_ asset: PHAsset) -> some View {
        let isSelected = asset.localIdentifier == selectedAssetID
        return Button {
            selectedAssetID = isSelected ? nil : asset.localIdentifier
        } label: {
            PhotoAssetImage(assetIdentifier: asset.localIdentifier)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let created = asset.creationDate {
                        Text(Self.timeLabel(created))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.45), in: .capsule)
                            .padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("사진")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 사진 조회

    private func loadPhotos() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        authStatus = status
        guard status == .authorized || status == .limited else { return }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            pointDate.addingTimeInterval(-Self.window) as NSDate,
            pointDate.addingTimeInterval(Self.window) as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            fetched.append(asset)
        }
        assets = fetched
    }

    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 사진 자산 썸네일

/// 사진 보관함 자산 식별자로 썸네일을 불러와 보여준다.
/// 다른 기기에서 추가된 메모는 cloudIdentifier로 이 기기의 원본을 다시 찾는다.
struct PhotoAssetImage: View {
    let assetIdentifier: String
    var cloudIdentifier: String? = nil

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(.rect(cornerRadius: 8))
            .task(id: assetIdentifier) {
                guard let resolved = PhotoAssetLoader.resolvedLocalIdentifier(
                    local: assetIdentifier, cloud: cloudIdentifier) else { return }
                let side = max(geo.size.width, geo.size.height) * 3
                image = await PhotoAssetLoader.image(
                    identifier: resolved,
                    targetSize: CGSize(width: side, height: side))
            }
        }
    }
}

/// 사진 보관함 자산 식별자로 이미지를 불러오는 공용 로더.
enum PhotoAssetLoader {
    /// 다른 기기에서 만든 클라우드 식별자 → 이 기기의 로컬 식별자 변환 결과를 기억해 둔다.
    private static var cloudToLocal: [String: String] = [:]

    /// 로컬 식별자(이 기기)와 클라우드 식별자(기기 공통) 중 이 기기에서 열 수 있는 것을 고른다.
    /// 다른 기기에서 추가한 메모는 로컬 식별자가 안 맞으므로 iCloud 사진 식별자로 다시 찾는다.
    static func resolvedLocalIdentifier(local: String?, cloud: String?) -> String? {
        if let local,
           PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject != nil {
            return local
        }
        guard let cloud else { return nil }
        if let cached = cloudToLocal[cloud] { return cached }
        let cloudID = PHCloudIdentifier(stringValue: cloud)
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: [cloudID])
        guard let resolved = try? mappings[cloudID]?.get() else { return nil }
        cloudToLocal[cloud] = resolved
        return resolved
    }

    /// 로컬 식별자들의 기기 공통(iCloud) 식별자. 메모를 만들 때 함께 저장해 둔다.
    static func cloudIdentifiers(forLocal identifiers: [String]) -> [String: String] {
        guard !identifiers.isEmpty else { return [:] }
        let mappings = PHPhotoLibrary.shared()
            .cloudIdentifierMappings(forLocalIdentifiers: identifiers)
        var result: [String: String] = [:]
        for (local, mapping) in mappings {
            if let cloud = try? mapping.get().stringValue {
                result[local] = cloud
            }
        }
        return result
    }

    /// 사진의 촬영 시각.
    static func creationDate(identifier: String) -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            .firstObject?.creationDate
    }

    static func image(
        identifier: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill
    ) async -> UIImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        // highQualityFormat은 콜백이 한 번만 와서 continuation을 중복 재개하지 않는다.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: contentMode, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
