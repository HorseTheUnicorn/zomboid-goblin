// Read-only asset inspection through the exact Assimp DLL shipped with PZ.
// Compile first, then run with the game's jar on the classpath; writes JSON.
import jassimp.*;
import java.nio.file.*;
import java.util.*;

class InspectPzMesh {
    static AiBuiltInWrapperProvider provider = new AiBuiltInWrapperProvider();
    static String quote(String s) { return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""; }
    static String matrix(AiMatrix4f m) {
        List<String> values = new ArrayList<>();
        for(int r=0;r<4;r++) for(int c=0;c<4;c++) values.add(Float.toString(m.get(r,c)));
        return "["+String.join(",",values)+"]";
    }
    static String node(AiNode n) {
        List<String> children = new ArrayList<>();
        for(AiNode c:n.getChildren()) children.add(node(c));
        return "{\"name\":"+quote(n.getName())+",\"matrix\":"+matrix(n.getTransform(provider))+",\"children\":["+String.join(",",children)+"]}";
    }
    static String mesh(AiMesh m) {
        List<String> vertices=new ArrayList<>(), uv=new ArrayList<>(), faces=new ArrayList<>(), bones=new ArrayList<>();
        for(int i=0;i<m.getNumVertices();i++) {
            vertices.add("["+m.getPositionX(i)+","+m.getPositionY(i)+","+m.getPositionZ(i)+"]");
            uv.add("["+m.getTexCoordU(i,0)+","+m.getTexCoordV(i,0)+"]");
        }
        for(int i=0;i<m.getNumFaces();i++) {
            List<String> ids=new ArrayList<>();
            for(int j=0;j<m.getFaceNumIndices(i);j++) ids.add(Integer.toString(m.getFaceVertex(i,j)));
            faces.add("["+String.join(",",ids)+"]");
        }
        for(AiBone b:m.getBones()) {
            List<String> weights=new ArrayList<>();
            for(AiBoneWeight w:b.getBoneWeights()) weights.add("["+w.getVertexId()+","+w.getWeight()+"]");
            bones.add("{\"name\":"+quote(b.getName())+",\"offset\":"+matrix(b.getOffsetMatrix(provider))+",\"weights\":["+String.join(",",weights)+"]}");
        }
        return "{\"name\":"+quote(m.getName())+",\"vertices\":["+String.join(",",vertices)+"],\"uv\":["+String.join(",",uv)+"],\"faces\":["+String.join(",",faces)+"],\"bones\":["+String.join(",",bones)+"]}";
    }
    static String animation(AiAnimation a) {
        List<String> channels=new ArrayList<>();
        for(AiNodeAnim n:a.getChannels()) {
            List<String> p=new ArrayList<>(),q=new ArrayList<>(),s=new ArrayList<>();
            for(int i=0;i<n.getNumPosKeys();i++) p.add("["+n.getPosKeyTime(i)+","+n.getPosKeyX(i)+","+n.getPosKeyY(i)+","+n.getPosKeyZ(i)+"]");
            for(int i=0;i<n.getNumRotKeys();i++) q.add("["+n.getRotKeyTime(i)+","+n.getRotKeyW(i)+","+n.getRotKeyX(i)+","+n.getRotKeyY(i)+","+n.getRotKeyZ(i)+"]");
            for(int i=0;i<n.getNumScaleKeys();i++) s.add("["+n.getScaleKeyTime(i)+","+n.getScaleKeyX(i)+","+n.getScaleKeyY(i)+","+n.getScaleKeyZ(i)+"]");
            channels.add("{\"name\":"+quote(n.getNodeName())+",\"position\":["+String.join(",",p)+"],\"rotation\":["+String.join(",",q)+"],\"scale\":["+String.join(",",s)+"]}");
        }
        return "{\"name\":"+quote(a.getName())+",\"duration\":"+a.getDuration()+",\"ticks_per_second\":"+a.getTicksPerSecond()+",\"channels\":["+String.join(",",channels)+"]}";
    }
    public static void main(String[] args) throws Exception {
        Jassimp.setLibraryLoader(new JassimpLibraryLoader() {
            public void loadLibrary() { System.load(Path.of(args[0],"jassimp64.dll").toString()); }
        });
        // FileTask_LoadMesh.loadX flags, plus structural validation.
        AiScene scene=Jassimp.importFile(args[1],EnumSet.of(AiPostProcessSteps.FIND_INSTANCES,
            AiPostProcessSteps.MAKE_LEFT_HANDED,AiPostProcessSteps.LIMIT_BONE_WEIGHTS,
            AiPostProcessSteps.TRIANGULATE,AiPostProcessSteps.OPTIMIZE_MESHES,
            AiPostProcessSteps.REMOVE_REDUNDANT_MATERIALS,AiPostProcessSteps.JOIN_IDENTICAL_VERTICES,
            AiPostProcessSteps.VALIDATE_DATA_STRUCTURE));
        List<String> meshes=new ArrayList<>(),animations=new ArrayList<>();
        for(AiMesh m:scene.getMeshes()) meshes.add(mesh(m));
        for(AiAnimation a:scene.getAnimations()) animations.add(animation(a));
        String json="{\"source\":"+quote(args[1])+",\"root\":"+node(scene.getSceneRoot(provider))+",\"meshes\":["+String.join(",",meshes)+"],\"animations\":["+String.join(",",animations)+"]}";
        Files.writeString(Path.of(args[2]),json);
        System.out.println("Imported "+args[1]+": "+scene.getNumMeshes()+" meshes, "+scene.getNumAnimations()+" animations -> "+args[2]);
    }
}
