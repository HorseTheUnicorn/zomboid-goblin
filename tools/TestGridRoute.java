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
        check(GridRoute.search(start, goal, 0, 1, edge).status() == GridRoute.Status.BUDGET_EXHAUSTED,
                "budget exhaustion differs from a sealed region");
        check(GridRoute.search(start, goal, 0, 100, (a,b)->false).status() == GridRoute.Status.UNREACHABLE,
                "sealed region reported unreachable");
        check(GridRoute.search(start, start, 0, 100, edge).status() == GridRoute.Status.ARRIVED,
                "same cell is arrival, not failure");
        check(GridRoute.search(start, goal, Double.NaN, 100, edge).status() == GridRoute.Status.INVALID,
                "invalid input classified");
        check(GridRoute.search(start, goal, 0, 200, edge).status() == GridRoute.Status.FOUND,
                "successful detour classified");
        var localTarget = GridRoute.nextPoint(List.of(), 0, 10.1, 20.1, 0, 10.9, 20.9, 0);
        check(localTarget != null && localTarget.x() == 10.9 && localTarget.y() == 20.9,
                "empty route permits final movement within destination tile");
        check(GridRoute.nextPoint(List.of(), 0, 10.9, 20.1, 0, 11.1, 20.1, 0) == null,
                "failed route cannot cross unchecked adjacent edge");
        check(GridRoute.nextPoint(List.of(), 0, 10.1, 20.1, 0, 10.2, 20.2, 1) == null,
                "same XY never permits a floor transition");
        check(GridRoute.nextPoint(List.of(), 0, -0.1, 0, 0, 0.1, 0, 0) == null,
                "negative coordinates use floor, not truncation");
        var waypoint = GridRoute.nextPoint(List.of(new Cell(11,20)), 0, 10.9,20.1,0,15.1,20.1,0);
        check(waypoint != null && waypoint.x() == 11.5 && waypoint.y() == 20.5,
                "existing route uses next checked waypoint, not direct goal");
        check(GridRoute.nextPoint(List.of(), 0, Double.NaN,0,0,0,0,0) == null,
                "non-finite movement rejected");
        System.out.println("GridRoute: 17 scenarios passed");
    }
}
