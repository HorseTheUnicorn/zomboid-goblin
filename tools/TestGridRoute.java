import com.horsetheunicorn.goblinsurvivor.GridRoute;
import com.horsetheunicorn.goblinsurvivor.GridRoute.Cell;
import java.util.List;

/** Executable algorithm tests, independent of PZ/graphics initialization. */
public class TestGridRoute {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        Cell start = new Cell(0,0), goal = new Cell(4,0);
        var edge = (java.util.function.BiPredicate<Cell, Cell>)(a,b) ->
                Math.abs(b.x()) <= 6 && Math.abs(b.y()) <= 6
                && !(b.x() == 2 && b.y() < 2);
        List<Cell> route = GridRoute.find(start, goal, 0, 200, edge);
        check(!route.isEmpty() && route.getLast().equals(goal), "route around wall");
        Cell prev = start;
        for (Cell next : route) {
            check(edge.test(prev,next), "every edge collision-checked");
            check(Math.abs(prev.x()-next.x()) + Math.abs(prev.y()-next.y()) == 1, "no corner cutting");
            prev = next;
        }
        check(GridRoute.find(start, goal, 0, 1, edge).isEmpty(), "budget enforced");
        check(GridRoute.find(start, goal, 0, 100, (a,b)->false).isEmpty(), "sealed start");
        check(GridRoute.find(start, start, 0, 100, edge).isEmpty(), "already arrived");
        var near = GridRoute.find(start, goal, 1, 200, edge);
        check(!near.isEmpty() && !near.getLast().equals(goal), "follow stopping radius");
        System.out.println("GridRoute: 6 scenarios passed");
    }
}
