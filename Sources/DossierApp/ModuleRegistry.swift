import DossierCore
import GraphModule
import ProfileModule
import CommsModule
import MailSearchModule
import ActivityModule
import EnvironmentModule
import PhotosModule
import BiomeModule
import RawModule

/// The single place where the app's modules are listed. Order within a sidebar group
/// follows the order here; groups are ordered by `SidebarGroup.order`.
enum ModuleRegistry {
    static let modules: [any DossierModule] = [
        GraphModule(),
        ProfileModule(),
        CommsModule(),
        MailSearchModule(),
        ActivityModule(),
        EnvironmentModule(),
        PhotosModule(),
        BiomeModule(),
        RawModule(),
    ]
}
