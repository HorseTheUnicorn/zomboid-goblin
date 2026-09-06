package com.horsetheunicorn.goblinsurvivor;

import java.util.*;
import java.util.function.BiPredicate;

/** Bounded cardinal A*: collision policy belongs to the world adapter. */
public final class GridRoute {
    public record Cell(int x, int y) { }
    public record Point(double x, double y) { }
    public enum Status { FOUND, ARRIVED, UNREACHABLE, BUDGET_EXHAUSTED, INVALID }
    public record Result(List<Cell> path, Status status, int expanded) { }
    private record Node(Cell cell, double cost, double score) { }
    private GridRoute() { }

    /** Resolve the next waypoint, including the final approach inside a tile.
     * An exhausted route never authorizes crossing an unchecked tile edge.
     */
    public static Point nextPoint(List<Cell> route, int waypoint,
            double x, double y, double z, double tx, double ty, double tz) {
        if (!Double.isFinite(x) || !Double.isFinite(y) || !Double.isFinite(z)
                || !Double.isFinite(tx) || !Double.isFinite(ty) || !Double.isFinite(tz)
                || Math.floor(z) != Math.floor(tz) || waypoint < 0) return null;
        if (waypoint < route.size()) {
            Cell next = route.get(waypoint);
            return new Point(next.x() + 0.5, next.y() + 0.5);
        }
        if (Math.floor(x) == Math.floor(tx) && Math.floor(y) == Math.floor(ty))
            return new Point(tx, ty);
        return null;
    }

    public static List<Cell> find(Cell start, Cell goal, double stopRadius, int budget,
            BiPredicate<Cell, Cell> canStep) {
        return search(start, goal, stopRadius, budget, canStep).path();
    }

    public static Result search(Cell start, Cell goal, double stopRadius, int budget,
            BiPredicate<Cell, Cell> canStep) {
        if (budget <= 0 || !Double.isFinite(stopRadius) || stopRadius < 0)
            return new Result(List.of(), Status.INVALID, 0);
        PriorityQueue<Node> open = new PriorityQueue<>(Comparator.comparingDouble(Node::score));
        Map<Cell, Double> cost = new HashMap<>();
        Map<Cell, Cell> parent = new HashMap<>();
        cost.put(start, 0.0);
        open.add(new Node(start, 0, distance(start, goal)));
        int expanded = 0;
        while (!open.isEmpty() && expanded < budget) {
            Node node = open.remove();
            if (node.cost() != cost.getOrDefault(node.cell(), Double.POSITIVE_INFINITY)) continue;
            expanded++;
            Cell here = node.cell();
            if (distance(here, goal) <= stopRadius) {
                LinkedList<Cell> path = new LinkedList<>();
                while (!here.equals(start)) {
                    path.addFirst(here);
                    here = parent.get(here);
                }
                return new Result(List.copyOf(path), path.isEmpty() ? Status.ARRIVED : Status.FOUND, expanded);
            }
            for (int[] d : new int[][] {{1,0},{0,1},{-1,0},{0,-1}}) {
                Cell next = new Cell(here.x() + d[0], here.y() + d[1]);
                if (!canStep.test(here, next)) continue;
                double nextCost = node.cost() + 1;
                if (nextCost >= cost.getOrDefault(next, Double.POSITIVE_INFINITY)) continue;
                cost.put(next, nextCost);
                parent.put(next, here);
                open.add(new Node(next, nextCost, nextCost + Math.max(0, distance(next, goal) - stopRadius)));
            }
        }
        return new Result(List.of(), open.isEmpty() ? Status.UNREACHABLE : Status.BUDGET_EXHAUSTED, expanded);
    }

    private static double distance(Cell a, Cell b) {
        return Math.hypot((double)a.x() - b.x(), (double)a.y() - b.y());
    }
}
